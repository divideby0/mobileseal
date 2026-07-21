import Foundation

/// On-disk layout of one gallery (spec §6 / docs/formats.md §Layout):
///   {root}/gallery.meta      envelope metadata + epoch keyring
///   {root}/chunks/{hex}      encrypted content chunks (CAS)
///   {root}/manifest/{hex}    encrypted inventory objects (CAS)
///   {root}/HEAD              pointer to the current inventory object
///   {root}/wal/{txid}/       staging for in-flight mutations
///   {root}/unlock.throttle   LOCAL unlock rate-limit sidecar (not part
///                            of the cross-platform contract)
struct VaultLayout: Sendable {
    let root: URL

    var metaURL: URL { root.appendingPathComponent("gallery.meta") }
    var chunksDir: URL { root.appendingPathComponent("chunks") }
    var manifestDir: URL { root.appendingPathComponent("manifest") }
    var headURL: URL { root.appendingPathComponent("HEAD") }
    var walDir: URL { root.appendingPathComponent("wal") }
    var throttleURL: URL { root.appendingPathComponent("unlock.throttle") }

    func chunkURL(_ address: ChunkAddress) -> URL {
        chunksDir.appendingPathComponent(address.hex)
    }
    func inventoryURL(_ address: ChunkAddress) -> URL {
        manifestDir.appendingPathComponent(address.hex)
    }
}

/// Filesystem primitives with explicit durability. Every mutation the
/// commit protocol makes goes through these so the fsync ordering in
/// docs/formats.md §Commit protocol is enforced in one place.
enum FS {
    static func write(_ bytes: [UInt8], to url: URL, fsync: Bool) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: Data(bytes)) else {
            throw VaultError.ioFailure(operation: "create", path: url.path)
        }
        if fsync { try fsyncFile(url) }
    }

    static func fsyncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw VaultError.ioFailure(operation: "open", path: url.path) }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) >= 0 || fsync(fd) == 0 else {
            throw VaultError.ioFailure(operation: "fsync", path: url.path)
        }
    }

    static func fsyncDir(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw VaultError.ioFailure(operation: "opendir", path: url.path) }
        defer { close(fd) }
        // The commit protocol's fsync ordering is normative
        // (docs/formats.md §Commit protocol), so a failed directory
        // sync surfaces instead of being swallowed (wave-001 #11).
        guard fsync(fd) == 0 else {
            throw VaultError.ioFailure(operation: "fsyncdir", path: url.path)
        }
    }

    /// Rename that treats an existing destination as success when the
    /// destination is content-addressed (CAS no-overwrite: an existing
    /// address is never rewritten).
    static func publishCAS(from src: URL, to dst: URL) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: src)
            return
        }
        do {
            try FileManager.default.moveItem(at: src, to: dst)
        } catch CocoaError.fileWriteFileExists {
            try? FileManager.default.removeItem(at: src)
        } catch {
            throw VaultError.ioFailure(operation: "rename", path: dst.path)
        }
    }

    /// Bounded read: the size bound is enforced BEFORE the bytes are
    /// materialized (stat via the open descriptor, then a capped
    /// `read(2)` loop — no TOCTOU window), so a hostile oversized file
    /// cannot demand a pathological allocation (wave-001 claude-code
    /// #3; Codex A8/B13).
    static func read(_ url: URL, object: VaultObjectKind, maxBytes: Int = .max) throws -> [UInt8] {
        func unreadable() -> VaultError {
            switch object {
            case .head: return VaultError.corruptHead
            case .galleryMeta: return VaultError.notAVault(path: url.path)
            case .chunk, .inventory, .manifest:
                return VaultError.ioFailure(operation: "read", path: url.path)
            }
        }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw unreadable() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw unreadable()
        }
        guard info.st_size <= Int64(maxBytes) else {
            throw VaultError.boundsViolation(object, field: "object_length")
        }
        var out = [UInt8](repeating: 0, count: Int(info.st_size))
        var total = 0
        let wanted = out.count
        try out.withUnsafeMutableBytes { raw in
            while total < wanted {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: total), wanted - total)
                if n == 0 { break }  // file shrank underneath us
                guard n > 0 else {
                    throw VaultError.ioFailure(operation: "read", path: url.path)
                }
                total += n
            }
        }
        if total < wanted { out.removeLast(wanted - total) }
        return out
    }
}

/// Steps of the commit sequence, in order. Fault-injection tests abort
/// after each step and assert recovery lands on full pre- or full
/// post-state (green gate 4 / Codex B8).
enum CommitStep: Int, CaseIterable, Sendable, Comparable {
    case stagedChunksWritten = 0
    case stagedInventoryWritten
    case chunksPublished
    case chunksDirSynced
    case inventoryPublished
    case manifestDirSynced
    case headSwapped
    case headDirSynced
    case walCleaned

    static func < (a: CommitStep, b: CommitStep) -> Bool { a.rawValue < b.rawValue }
}

/// Thrown by the failpoint hook to simulate a crash mid-commit; the
/// vault directory is left exactly as a real crash at that step would.
struct SimulatedCrash: Error, Equatable {
    let step: CommitStep
}

/// Test-only hook: aborts the commit after the given step completes.
struct CommitFailpoint: Sendable {
    let abortAfter: CommitStep?

    static let none = CommitFailpoint(abortAfter: nil)

    func check(_ completed: CommitStep) throws {
        if let abortAfter, completed == abortAfter {
            throw SimulatedCrash(step: completed)
        }
    }
}

/// Steps of the v0 → v1 migration state machine (GOAL WS B.6), in
/// order. Crash-injection tests abort after each step and prove the
/// re-run is an idempotent no-op prefix. The WAL commit inside the
/// machine additionally exposes every `CommitStep` failpoint.
enum MigrationStep: Int, CaseIterable, Sendable, Comparable {
    case identityEnsured = 0
    case genesisStaged
    case manifestStaged
    case committed
    case highWaterInitialized

    static func < (a: MigrationStep, b: MigrationStep) -> Bool { a.rawValue < b.rawValue }
}

/// Thrown by the migration failpoint hook to simulate a crash between
/// migration steps.
struct SimulatedMigrationCrash: Error, Equatable {
    let step: MigrationStep
}

/// Test-only hook: aborts the migration after the given step.
struct MigrationFailpoint: Sendable {
    let abortAfter: MigrationStep?

    static let none = MigrationFailpoint(abortAfter: nil)

    func check(_ completed: MigrationStep) throws {
        if let abortAfter, completed == abortAfter {
            throw SimulatedMigrationCrash(step: completed)
        }
    }
}

/// One WAL-staged transaction (docs/formats.md §Commit protocol).
/// Chunks stream into `wal/{txid}/` as they are produced (so imports
/// never hold a whole file in memory); `commit` then publishes and
/// swaps HEAD. The commit point is the atomic HEAD rename; everything
/// before it is invisible to readers (new CAS objects are unreferenced
/// until HEAD points at an inventory that references them).
final class CommitTx {
    let layout: VaultLayout
    let txid: String
    private let txDir: URL
    private let txChunks: URL
    private let txManifest: URL
    private var stagedChunks: [ChunkAddress] = []

    init(layout: VaultLayout, txid: String = UUID().uuidString.lowercased()) throws {
        self.layout = layout
        self.txid = txid
        self.txDir = layout.walDir.appendingPathComponent(txid)
        self.txChunks = txDir.appendingPathComponent("chunks")
        self.txManifest = txDir.appendingPathComponent("manifest")
        let fm = FileManager.default
        try fm.createDirectory(at: txChunks, withIntermediateDirectories: true)
        try fm.createDirectory(at: txManifest, withIntermediateDirectories: true)
    }

    /// Stages one sealed chunk object (write + fsync into the WAL).
    func stageChunk(_ bytes: [UInt8]) throws -> ChunkAddress {
        let address = ChunkAddress.compute(over: bytes)
        if !stagedChunks.contains(address) {
            try FS.write(bytes, to: txChunks.appendingPathComponent(address.hex), fsync: true)
            stagedChunks.append(address)
        }
        return address
    }

    /// Publishes staged objects and swaps HEAD. Returns the committed
    /// inventory object's address. v0 shape: HEAD is the plain pointer.
    func commit(inventoryObject: [UInt8], failpoint: CommitFailpoint = .none) throws -> ChunkAddress {
        try commit(
            manifestObject: inventoryObject, failpoint: failpoint,
            headBytes: { Head.serialize($0) })
    }

    /// Generalized commit: `headBytes` renders the HEAD file for the
    /// committed object's address (v0 plain pointer, or v1 signed
    /// sealed descriptor). The commit point remains the atomic HEAD
    /// rename regardless of HEAD format.
    func commit(
        manifestObject: [UInt8], failpoint: CommitFailpoint = .none,
        headBytes: (ChunkAddress) throws -> [UInt8]
    ) throws -> ChunkAddress {
        let fm = FileManager.default
        try failpoint.check(.stagedChunksWritten)

        // Stage the manifest/inventory object (fsync).
        let inventoryAddress = ChunkAddress.compute(over: manifestObject)
        try FS.write(
            manifestObject, to: txManifest.appendingPathComponent(inventoryAddress.hex), fsync: true)
        try failpoint.check(.stagedInventoryWritten)

        // Publish chunks into the CAS (no-overwrite), then sync dir.
        for address in stagedChunks {
            try FS.publishCAS(
                from: txChunks.appendingPathComponent(address.hex),
                to: layout.chunkURL(address))
        }
        try failpoint.check(.chunksPublished)
        try FS.fsyncDir(layout.chunksDir)
        try failpoint.check(.chunksDirSynced)

        // Publish the inventory object, then sync its dir.
        try FS.publishCAS(
            from: txManifest.appendingPathComponent(inventoryAddress.hex),
            to: layout.inventoryURL(inventoryAddress))
        try failpoint.check(.inventoryPublished)
        try FS.fsyncDir(layout.manifestDir)
        try failpoint.check(.manifestDirSynced)

        // COMMIT POINT: atomic HEAD swap (temp + fsync + rename).
        let headTmp = layout.root.appendingPathComponent("HEAD.tmp")
        try FS.write(try headBytes(inventoryAddress), to: headTmp, fsync: true)
        do {
            _ = try fm.replaceItemAt(layout.headURL, withItemAt: headTmp)
        } catch {
            throw VaultError.ioFailure(operation: "rename", path: layout.headURL.path)
        }
        try failpoint.check(.headSwapped)
        try FS.fsyncDir(layout.root)
        try failpoint.check(.headDirSynced)

        // Clean the WAL (best-effort; recovery also deletes orphans).
        try? fm.removeItem(at: txDir)
        try failpoint.check(.walCleaned)

        return inventoryAddress
    }

    /// Discards the staged transaction (import failed before commit).
    func abort() {
        try? FileManager.default.removeItem(at: txDir)
    }
}

enum Recovery {
    /// Startup recovery (docs/formats.md §Recovery): every WAL dir is
    /// an uncommitted or already-published transaction — delete all.
    /// Also removes a leftover HEAD.tmp. Never touches CAS contents.
    static func recover(layout: VaultLayout) {
        let fm = FileManager.default
        if let subdirs = try? fm.contentsOfDirectory(atPath: layout.walDir.path) {
            for sub in subdirs {
                try? fm.removeItem(at: layout.walDir.appendingPathComponent(sub))
            }
        }
        try? fm.removeItem(at: layout.root.appendingPathComponent("HEAD.tmp"))
    }
}

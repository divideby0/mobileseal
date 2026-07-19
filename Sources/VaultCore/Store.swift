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
        _ = fsync(fd)  // directory fsync is advisory on some filesystems
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

    static func read(_ url: URL, object: VaultObjectKind, maxBytes: Int = .max) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            switch object {
            case .head: throw VaultError.corruptHead
            case .chunk: throw VaultError.ioFailure(operation: "read", path: url.path)
            case .inventory: throw VaultError.ioFailure(operation: "read", path: url.path)
            case .galleryMeta: throw VaultError.notAVault(path: url.path)
            }
        }
        guard data.count <= maxBytes else {
            throw VaultError.boundsViolation(object, field: "object_length")
        }
        return [UInt8](data)
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
    /// inventory object's address.
    func commit(inventoryObject: [UInt8], failpoint: CommitFailpoint = .none) throws -> ChunkAddress {
        let fm = FileManager.default
        try failpoint.check(.stagedChunksWritten)

        // Stage the inventory object (fsync).
        let inventoryAddress = ChunkAddress.compute(over: inventoryObject)
        try FS.write(
            inventoryObject, to: txManifest.appendingPathComponent(inventoryAddress.hex), fsync: true)
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
        try FS.write(Head.serialize(inventoryAddress), to: headTmp, fsync: true)
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

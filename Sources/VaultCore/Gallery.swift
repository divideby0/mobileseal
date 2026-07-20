import Clibsodium
import Foundation

/// Byte source for an import: pull-based so files stream through a
/// fixed-size secure buffer and are never held whole in memory.
/// Internal (not private) so tests can inject a source that mutates
/// between passes and pin the `sourceChangedDuringImport` guards.
protocol ChunkSource: ~Copyable {
    /// Fills `buffer` from the current position with up to `max`
    /// bytes; returns the byte count (0 at EOF). Never writes past
    /// `max`.
    mutating func read(into buffer: borrowing SecureBytes, max: Int) throws -> Int
    mutating func rewind() throws
}

private struct FileSource: ChunkSource, ~Copyable {
    // (deinit closes the descriptor; the type is move-only for it)
    let url: URL
    var fd: Int32

    init(url: URL) throws {
        self.url = url
        self.fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw VaultError.ioFailure(operation: "open", path: url.path) }
    }

    mutating func read(into buffer: borrowing SecureBytes, max: Int) throws -> Int {
        precondition(max <= buffer.count)
        return try buffer.withUnsafeMutableBytes { raw -> Int in
            var total = 0
            while total < max {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: total), max - total)
                if n == 0 { break }
                guard n > 0 else {
                    throw VaultError.ioFailure(operation: "read", path: url.path)
                }
                total += n
            }
            return total
        }
    }

    mutating func rewind() throws {
        guard lseek(fd, 0, SEEK_SET) == 0 else {
            throw VaultError.ioFailure(operation: "lseek", path: url.path)
        }
    }

    deinit { close(fd) }
}

private struct MemorySource: ChunkSource {
    let bytes: [UInt8]
    var offset = 0

    mutating func read(into buffer: borrowing SecureBytes, max: Int) throws -> Int {
        let n = min(max, bytes.count - offset)
        guard n > 0 else { return 0 }
        buffer.withUnsafeMutableBytes { raw in
            bytes.withUnsafeBufferPointer { src in
                raw.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: offset), byteCount: n)
            }
        }
        offset += n
        return n
    }

    mutating func rewind() { offset = 0 }
}

/// The single holder of write authority for one gallery (api-shape §3).
/// Mutations stage into `wal/{txid}/` and become visible via the
/// atomic inventory-rename + HEAD-swap commit; a half-finished import
/// is a deletable staging directory, never a corrupt vault. Reads run
/// off-actor through `ChunkReader`s against immutable snapshots.
public actor Gallery {
    let layout: VaultLayout
    let meta: GalleryMeta
    let custodian: KeyCustodian
    let epoch: UInt32
    /// The current signed manifest (format v1) and this device's
    /// signing state.
    private var manifest: ManifestObject
    private let identity: DeviceIdentity
    private let deviceName: String
    private let rollbackStore: any RollbackStateStore
    /// Last HEAD counter this device wrote (or its recorded base);
    /// each commit signs counter + 1 (GOAL WS B.7).
    private var headCounter: UInt64
    /// Effective (tombstone-applied) entries — what readers and
    /// snapshots see. Recomputed per commit.
    private var visibleEntries: [InventoryEntry]
    private var failpoint: CommitFailpoint = .none
    private var continuations: [UUID: AsyncStream<InventorySnapshot>.Continuation] = [:]

    init(
        layout: VaultLayout, meta: GalleryMeta, custodian: KeyCustodian,
        manifest: ManifestObject, epoch: UInt32,
        identity: DeviceIdentity, deviceName: String,
        rollbackStore: any RollbackStateStore, headCounter: UInt64
    ) {
        self.layout = layout
        self.meta = meta
        self.custodian = custodian
        self.manifest = manifest
        self.epoch = epoch
        self.identity = identity
        self.deviceName = deviceName
        self.rollbackStore = rollbackStore
        self.headCounter = headCounter
        self.visibleEntries =
            manifest.state.effectiveView(galleryID: meta.galleryID).visibleEntries
    }

    // MARK: - Snapshots

    /// Structural snapshot of the current effective entries (Codex B6:
    /// no decrypted metadata rides in Sendable snapshot values).
    /// `generation` is the LOCAL commit revision (review Q5).
    public func snapshot() -> InventorySnapshot {
        InventorySnapshot(revision: manifest.localRevision, entries: visibleEntries)
    }

    /// Yields the current snapshot immediately, then one snapshot per
    /// committed mutation.
    public func snapshotStream() -> AsyncStream<InventorySnapshot> {
        let id = UUID()
        let current = InventorySnapshot(
            revision: manifest.localRevision, entries: visibleEntries)
        return AsyncStream { continuation in
            continuation.yield(current)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    // MARK: - Session-scoped accessors

    /// Off-actor read capability over the CURRENT effective entries.
    public func makeReader() -> ChunkReader {
        ChunkReader(
            layout: layout, galleryID: meta.galleryID, custodian: custodian,
            entries: visibleEntries)
    }

    /// The app's opaque metadata blob for `fileID` (Codex B6: served
    /// only through lock-checked accessors, never snapshots).
    public func metadata(for fileID: FileID) throws -> [UInt8] {
        guard !custodian.isLocked else { throw VaultError.vaultLocked }
        guard let e = visibleEntries.first(where: { $0.fileID == fileID }) else {
            throw VaultError.fileNotFound(fileID)
        }
        return e.metadata
    }

    /// Streaming range-read capability over the CURRENT inventory,
    /// decrypting through `provider` into `cache` (CED-12 WS A).
    /// Like `makeReader()`, per-generation: entries committed later
    /// are invisible to this reader.
    public func makeStreamingReader(
        provider: any SealedChunkProvider, cache: ResidentChunkCache
    ) -> StreamingReader {
        StreamingReader(
            galleryID: meta.galleryID, custodian: custodian,
            entries: visibleEntries, provider: provider, cache: cache)
    }

    // MARK: - Import

    /// Imports a file from disk, streaming it through a fixed secure
    /// buffer. Returns the new entry's file ID — a random UUID minted
    /// once per logical import (docs/formats.md §File identity).
    public func importFile(
        at url: URL, metadata: [UInt8] = [], chunkSize: UInt32 = VaultFormat.defaultChunkSize
    ) throws -> FileID {
        var source = try FileSource(url: url)
        return try importSource(&source, metadata: metadata, chunkSize: chunkSize)
    }

    /// Imports in-memory bytes (thumbnails, tests). The caller already
    /// holds these bytes in ordinary memory; custody guarantees start
    /// at the secure staging buffer.
    public func importBytes(
        _ bytes: [UInt8], metadata: [UInt8] = [], chunkSize: UInt32 = VaultFormat.defaultChunkSize
    ) throws -> FileID {
        var source = MemorySource(bytes: bytes)
        return try importSource(&source, metadata: metadata, chunkSize: chunkSize)
    }

    /// Internal seam (tests inject mutating sources; public entry
    /// points wrap it).
    func importSource<S: ChunkSource & ~Copyable>(
        _ source: inout S, metadata: [UInt8], chunkSize: UInt32
    ) throws -> FileID {
        guard !custodian.isLocked else { throw VaultError.vaultLocked }
        try ChunkGeometry.validate(chunkSize: chunkSize)
        guard metadata.count <= FormatV0.maxMetadataBlobBytes else {
            throw VaultError.boundsViolation(.inventory, field: "metadata_length")
        }

        let buffer = try SecureBytes(zeroed: Int(chunkSize))

        // Pass 1: dedup hash (domain-separated BLAKE2b-256 over the
        // whole plaintext) + true length.
        var hasher = CryptoCore.Blake2bStream(domain: FormatV0.dedupDomain)
        var unpaddedLength: UInt64 = 0
        while true {
            let n = try source.read(into: buffer, max: Int(chunkSize))
            if n == 0 { break }
            hasher.update(secure: buffer, count: n)
            unpaddedLength += UInt64(n)
        }
        let dedupHash = hasher.finalize()
        let fileID = FileID()

        // Dedup (green gate 1): identity = media bytes. A re-import
        // creates a NEW entry sharing the existing chunks — including
        // their AAD context (aadFileID/epoch/chunkSize) — re-storing
        // nothing. The shortcut only applies when every shared chunk
        // is still PRESENT in the CAS: if any went missing, we fall
        // through and re-seal, turning the natural user response to a
        // broken file ("import it again") into self-repair instead of
        // a second unreadable entry (wave-003 claude-code #4).
        if let existing = visibleEntries.first(where: {
            $0.dedupHash == dedupHash && $0.unpaddedLength == unpaddedLength
        }),
            existing.chunkAddresses.allSatisfy({
                FileManager.default.fileExists(atPath: layout.chunkURL($0).path)
            })
        {
            let entry = InventoryEntry(
                fileID: fileID, aadFileID: existing.aadFileID, epoch: existing.epoch,
                chunkSize: existing.chunkSize, unpaddedLength: existing.unpaddedLength,
                dedupHash: dedupHash, chunkAddresses: existing.chunkAddresses,
                metadata: metadata)
            try commitAppending(entry, stagedIn: nil)
            return fileID
        }

        // Pass 2: chunk, pad, seal, stage. A second hash runs over the
        // bytes actually sealed and must match pass 1 — a source whose
        // contents changed between passes (same length) would otherwise
        // commit chunks permanently mislabeled by the pass-1 dedup hash
        // (wave-002 claude-code #6).
        try source.rewind()
        var sealedHasher = CryptoCore.Blake2bStream(domain: FormatV0.dedupDomain)
        let tx = try CommitTx(layout: layout)
        var addresses: [ChunkAddress] = []
        let chunkCount = ChunkGeometry.chunkCount(
            unpaddedLength: unpaddedLength, chunkSize: chunkSize)
        do {
            for index in 0..<chunkCount {
                // Zero the whole buffer first: the pad region must be
                // zero bytes (docs/formats.md §Padding), and stale
                // bytes from the previous chunk must never leak in.
                buffer.withUnsafeMutableBytes { sodium_memzero($0.baseAddress!, $0.count) }
                let want = Int(
                    ChunkGeometry.unpaddedLength(
                        ofChunk: index, unpaddedLength: unpaddedLength, chunkSize: chunkSize))
                let got = try source.read(into: buffer, max: want)
                guard got == want else {
                    throw VaultError.sourceChangedDuringImport
                }
                sealedHasher.update(secure: buffer, count: got)
                let paddedLen = ChunkGeometry.paddedLength(
                    ofChunk: index, unpaddedLength: unpaddedLength, chunkSize: chunkSize)
                let sealed = try sealChunk(
                    buffer, paddedLen: paddedLen, lease: custodian.leaseKey(),
                    fileID: fileID, index: index)
                addresses.append(try tx.stageChunk(sealed))
            }
            guard sealedHasher.finalize() == dedupHash else {
                throw VaultError.sourceChangedDuringImport
            }
            let entry = InventoryEntry(
                fileID: fileID, aadFileID: fileID, epoch: epoch, chunkSize: chunkSize,
                unpaddedLength: unpaddedLength, dedupHash: dedupHash,
                chunkAddresses: addresses, metadata: metadata)
            try commitAppending(entry, stagedIn: tx)
            return fileID
        } catch let crash as SimulatedCrash {
            // Fault-injection: leave the WAL dir exactly as a real
            // crash would; startup recovery must clean it up.
            throw crash
        } catch {
            tx.abort()
            throw error
        }
    }

    /// Signs `entry` as this device and commits manifest(revision+1,
    /// entries ∪ {entry}) through the commit protocol.
    private func commitAppending(_ entry: InventoryEntry, stagedIn tx: CommitTx?) throws {
        var next = manifest
        let signed = SignedAddEntry.minted(
            entry: entry, author: identity, migratedFromV0: false, galleryID: meta.galleryID)
        next.state.entries = ManifestState.mergeEntries(
            next.state.entries, [signed], galleryID: meta.galleryID)
        try commitManifest(&next, stagedIn: tx)
    }

    // MARK: - Trust (GOAL WS A.2) and delete (GOAL WS B.3/C.2)

    /// TOFU self-registration: commits a trust-list update naming this
    /// device if it is not yet listed. Registration also folds into
    /// any other commit automatically — this explicit form exists so
    /// enrollment happens deterministically at first write-capable
    /// unlock, not lazily at first import.
    public func ensureDeviceRegistered() throws {
        guard !manifest.state.trustList.contains(identity.publicKey) else { return }
        var next = manifest
        try commitManifest(&next, stagedIn: nil)
    }

    /// Whether this device is in the current trust list (test surface).
    public var isDeviceRegistered: Bool {
        manifest.state.trustList.contains(identity.publicKey)
    }

    /// Devices in the current trust list (structural: public keys,
    /// roles, names — nothing secret).
    public func trustedDevices() -> [(publicKey: DevicePublicKey, name: String)] {
        manifest.state.trustList.devices.map { ($0.publicKey, $0.name) }
    }

    /// Emits signed tombstones for the given entries — the
    /// delete-for-everyone tier (GOAL WS C.2). The app passes the
    /// whole media AGGREGATE (original + linked thumbnail/Live-Photo
    /// entries); VaultCore records one tombstone per entry, each
    /// carrying the gallery-bound canonical digest of its target.
    /// Absent or already-tombstoned IDs are skipped (idempotent).
    /// Single-user semantics: this device is always authorized (it is
    /// trusted); the author-or-owner rule's full force arrives with
    /// sharing.
    public func deleteEntries(_ fileIDs: [FileID]) throws {
        let targets = Set(fileIDs)
        let present = manifest.state.entries.filter { targets.contains($0.fileID) }
        let alreadyTombstoned = Set(
            manifest.state.tombstones.map(\.targetFileID))
        let newTombstones = present
            .filter { !alreadyTombstoned.contains($0.fileID) }
            .map { entry in
                SignedTombstone.minted(
                    targetFileID: entry.fileID,
                    targetDigest: entry.canonicalDigest(galleryID: meta.galleryID),
                    author: identity, galleryID: meta.galleryID)
            }
        guard !newTombstones.isEmpty else { return }
        var next = manifest
        next.state.tombstones = ManifestState.mergeTombstones(
            next.state.tombstones, newTombstones)
        try commitManifest(&next, stagedIn: nil)
    }

    // MARK: - Commit core

    /// Seals `next` (with revision+1 and any pending TOFU registration
    /// folded in), signs a fresh HEAD descriptor with this device's
    /// next counter, and runs the commit protocol; publishes the new
    /// snapshot on success.
    private func commitManifest(_ next: inout ManifestObject, stagedIn tx: CommitTx?) throws {
        guard !custodian.isLocked else {
            tx?.abort()
            throw VaultError.vaultLocked
        }
        next.localRevision += 1
        // TOFU (WS A.2): a device not yet in the trust list registers
        // itself in the same commit — append-only union, version + 1,
        // member role (genesis owner role is minted at create/migrate).
        if !next.state.trustList.contains(identity.publicKey) {
            let devices = SignedTrustList.mergeDevices(
                next.state.trustList.devices,
                [
                    TrustedDevice(
                        publicKey: identity.publicKey, role: .member,
                        addedAtUnixMS: UInt64(Date().timeIntervalSince1970 * 1000),
                        name: deviceName)
                ])
            next.state.trustList = SignedTrustList.minted(
                listVersion: next.state.trustList.listVersion + 1,
                devices: devices, signer: identity, galleryID: meta.galleryID)
        }
        let counter = headCounter + 1
        let lease = try custodian.leaseKey()
        let object = try lease.withKey { dek in
            try next.sealObject(dek: dek, galleryID: meta.galleryID, epoch: epoch)
        }
        let commitTx = try tx ?? CommitTx(layout: layout)
        do {
            _ = try commitTx.commit(manifestObject: object, failpoint: failpoint) { address in
                let descriptor = SignedHeadDescriptor.minted(
                    manifestAddress: address, counter: counter,
                    author: identity, galleryID: meta.galleryID)
                return try lease.withKey { dek in
                    try HeadV1.serialize(
                        descriptor: descriptor, dek: dek, galleryID: meta.galleryID, epoch: epoch)
                }
            }
        } catch {
            // If the commit POINT was crossed (HEAD now names the new
            // manifest) before a later durability step failed, adopt
            // the post-state before rethrowing — otherwise this actor
            // would rebuild from stale memory and its next commit
            // would silently erase an already-visible entry (wave-003
            // codex #5).
            let committedAddress = ChunkAddress.compute(over: object)
            if let headData = FileManager.default.contents(atPath: layout.headURL.path),
                let parsed = try? HeadFile.parse([UInt8](headData)),
                parsed.address == committedAddress
            {
                adopt(next, counter: counter)
            } else if !(error is SimulatedCrash) {
                // Not crossed and not a simulated crash (whose WAL
                // state the recovery tests own): clean the staging dir
                // so repeated failures cannot accumulate unbounded WAL
                // directories (wave-003 claude-code #3).
                commitTx.abort()
            }
            throw error
        }
        adopt(next, counter: counter)
    }

    private func adopt(_ next: ManifestObject, counter: UInt64) {
        manifest = next
        headCounter = counter
        // High-water bookkeeping (WS B.7) is device-local state; a
        // failed write must not fail the already-durable commit — the
        // next unlock re-records the observed counter.
        try? rollbackStore.recordObservation(
            galleryID: meta.galleryID, signer: identity.publicKey, counter: counter)
        visibleEntries = next.state.effectiveView(galleryID: meta.galleryID).visibleEntries
        let snapshot = InventorySnapshot(
            revision: next.localRevision, entries: visibleEntries)
        for c in continuations.values { c.yield(snapshot) }
    }

    /// Seals one chunk under a leased DEK. Nonisolated so the closure
    /// capture of the move-only buffer stays outside actor isolation
    /// (the region checker rejects it there).
    private nonisolated func sealChunk(
        _ buffer: borrowing SecureBytes, paddedLen: Int, lease: KeyLease,
        fileID: FileID, index: UInt64
    ) throws -> [UInt8] {
        try lease.withKey { dek in
            try ChunkObject.seal(
                plaintext: buffer, plaintextLen: paddedLen, dek: dek,
                galleryID: meta.galleryID, fileID: fileID,
                chunkIndex: index, epoch: epoch)
        }
    }

    // MARK: - Test hooks

    func setCommitFailpoint(_ fp: CommitFailpoint) {
        failpoint = fp
    }

    /// The full signed manifest (test surface: merge/property suites
    /// inspect the CRDT state behind the effective view).
    func debugManifest() -> ManifestObject {
        manifest
    }
}

import Clibsodium
import Foundation

/// Byte source for an import: pull-based so files stream through a
/// fixed-size secure buffer and are never held whole in memory.
private protocol ChunkSource: ~Copyable {
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
    private var inventory: Inventory
    private var failpoint: CommitFailpoint = .none
    private var continuations: [UUID: AsyncStream<InventorySnapshot>.Continuation] = [:]

    init(
        layout: VaultLayout, meta: GalleryMeta, custodian: KeyCustodian,
        inventory: Inventory, epoch: UInt32
    ) {
        self.layout = layout
        self.meta = meta
        self.custodian = custodian
        self.inventory = inventory
        self.epoch = epoch
    }

    // MARK: - Snapshots

    /// Structural snapshot of the current inventory (Codex B6: no
    /// decrypted metadata rides in Sendable snapshot values).
    public func snapshot() -> InventorySnapshot {
        InventorySnapshot(inventory)
    }

    /// Yields the current snapshot immediately, then one snapshot per
    /// committed mutation.
    public func snapshotStream() -> AsyncStream<InventorySnapshot> {
        let id = UUID()
        let current = InventorySnapshot(inventory)
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

    /// Off-actor read capability over the CURRENT inventory.
    public func makeReader() -> ChunkReader {
        ChunkReader(
            layout: layout, galleryID: meta.galleryID, custodian: custodian,
            entries: inventory.entries)
    }

    /// The app's opaque metadata blob for `fileID` (Codex B6: served
    /// only through lock-checked accessors, never snapshots).
    public func metadata(for fileID: FileID) throws -> [UInt8] {
        guard !custodian.isLocked else { throw VaultError.vaultLocked }
        return try inventory.entry(for: fileID).metadata
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

    private func importSource<S: ChunkSource & ~Copyable>(
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
        // nothing.
        if let existing = inventory.entries.first(where: {
            $0.dedupHash == dedupHash && $0.unpaddedLength == unpaddedLength
        }) {
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

    /// Seals inventory(generation+1, entries + new entry) and runs the
    /// commit protocol; publishes the new snapshot on success.
    private func commitAppending(_ entry: InventoryEntry, stagedIn tx: CommitTx?) throws {
        guard !custodian.isLocked else {
            tx?.abort()
            throw VaultError.vaultLocked
        }
        var next = inventory
        next.generation += 1
        next.entries.append(entry)
        let lease = try custodian.leaseKey()
        let object = try lease.withKey { dek in
            try next.sealObject(dek: dek, galleryID: meta.galleryID, epoch: epoch)
        }
        let commitTx = try tx ?? CommitTx(layout: layout)
        _ = try commitTx.commit(inventoryObject: object, failpoint: failpoint)
        inventory = next
        let snapshot = InventorySnapshot(next)
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
}

import Foundation

/// Test/diagnostic instrumentation: counts chunk-object decrypts so
/// the random-access green gate can prove a mid-file range read
/// touches only the chunks it needs.
final class ReaderInstrumentation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordDecrypt() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var decryptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

/// Off-actor read capability (api-shape §4). Sendable and freely
/// shareable across tasks; every decrypt runs under the custodian's
/// read custody, so `lock()` revokes it: reads after lock — or reads
/// that lose the drain race — fail closed with `VaultError.vaultLocked`
/// and never return plaintext. Decryption goes straight into
/// `sodium_malloc`-backed `SecureBytes`; plaintext leaves only through
/// scoped borrowing closures.
public final class ChunkReader: Sendable {
    let layout: VaultLayout
    let galleryID: UUID
    let custodian: KeyCustodian
    // Immutable inventory view (structural + metadata blobs); metadata
    // is only served through the lock-checked accessor below.
    let entries: [InventoryEntry]
    let instrumentation: ReaderInstrumentation

    init(
        layout: VaultLayout, galleryID: UUID, custodian: KeyCustodian,
        entries: [InventoryEntry], instrumentation: ReaderInstrumentation = ReaderInstrumentation()
    ) {
        self.layout = layout
        self.galleryID = galleryID
        self.custodian = custodian
        self.entries = entries
        self.instrumentation = instrumentation
    }

    private func entry(for fileID: FileID) throws -> InventoryEntry {
        guard let e = entries.first(where: { $0.fileID == fileID }) else {
            throw VaultError.fileNotFound(fileID)
        }
        return e
    }

    /// Decrypts chunk `index` of `fileID` and hands `body` the padded
    /// plaintext buffer plus the number of CONTENT bytes it holds
    /// (tail chunks: unpadded remainder). AEAD tag and padding are
    /// verified before `body` runs.
    public func withDecryptedChunk<R>(
        fileID: FileID, index: UInt64,
        _ body: (borrowing SecureBytes, _ contentLength: Int) throws -> R
    ) throws -> R {
        let e = try entry(for: fileID)
        guard index < UInt64(e.chunkAddresses.count) else {
            throw VaultError.rangeOutOfBounds
        }
        let buffer = try SecureBytes(zeroed: Int(e.chunkSize))
        let contentLen = try decryptChunk(e, index: index, into: buffer)
        return try body(buffer, contentLen)
    }

    /// Random-access read: decrypts ONLY the chunks overlapping
    /// `offset..<offset+length` (green gate 2) and hands `body` a
    /// secure buffer holding exactly `length` bytes.
    public func readRange<R>(
        fileID: FileID, offset: UInt64, length: Int,
        _ body: (borrowing SecureBytes) throws -> R
    ) throws -> R {
        let e = try entry(for: fileID)
        guard length > 0, offset + UInt64(length) <= e.unpaddedLength else {
            throw VaultError.rangeOutOfBounds
        }
        let out = try SecureBytes(zeroed: length)
        let chunkSize = UInt64(e.chunkSize)
        let firstChunk = offset / chunkSize
        let lastChunk = (offset + UInt64(length) - 1) / chunkSize
        let scratch = try SecureBytes(zeroed: Int(e.chunkSize))
        var written = 0
        for index in firstChunk...lastChunk {
            let contentLen = try decryptChunk(e, index: index, into: scratch)
            let chunkStart = index * chunkSize
            let sliceStart = index == firstChunk ? Int(offset - chunkStart) : 0
            let want = min(contentLen - sliceStart, length - written)
            guard want > 0 else { throw VaultError.lengthMismatch }
            scratch.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    dst.baseAddress!.advanced(by: written)
                        .copyMemory(from: src.baseAddress!.advanced(by: sliceStart), byteCount: want)
                }
            }
            written += want
        }
        guard written == length else { throw VaultError.lengthMismatch }
        return try body(out)
    }

    /// Session-scoped metadata accessor (Codex B6): returns the app's
    /// opaque metadata blob for `fileID`; fails closed after lock.
    public func metadata(for fileID: FileID) throws -> [UInt8] {
        guard !custodian.isLocked else { throw VaultError.vaultLocked }
        return try entry(for: fileID).metadata
    }

    /// Deep (AEAD-tier) verification: decrypt-verifies every chunk of
    /// every entry and validates padding; reports CAS objects no entry
    /// references. This — not the sealed-plane address audit — is the
    /// end-to-end integrity check.
    public func verifyAuthenticity() throws -> DeepVerifyReport {
        var verifiedChunks = 0
        var referenced = Set<ChunkAddress>()
        for e in entries {
            let scratch = try SecureBytes(zeroed: Int(e.chunkSize))
            for index in 0..<UInt64(e.chunkAddresses.count) {
                _ = try decryptChunk(e, index: index, into: scratch)
                verifiedChunks += 1
            }
            referenced.formUnion(e.chunkAddresses)
        }
        let onDisk = (try? SealedVault.listCASDir(layout.chunksDir).addresses) ?? []
        let orphans = onDisk.filter { !referenced.contains($0) }
        return DeepVerifyReport(
            verifiedFiles: entries.count,
            verifiedChunks: verifiedChunks,
            orphanChunks: orphans)
    }

    /// Reads, authenticates, and pad-validates one chunk into `buffer`.
    /// Returns the chunk's CONTENT length (unpadded bytes).
    private func decryptChunk(
        _ e: InventoryEntry, index: UInt64, into buffer: borrowing SecureBytes
    ) throws -> Int {
        let address = e.chunkAddresses[Int(index)]
        let url = layout.chunkURL(address)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.missingChunk(address)
        }
        let stored = try FS.read(
            url, object: .chunk,
            maxBytes: ChunkObject.headerLength + Int(e.chunkSize) + CryptoCore.aeadTagBytes)
        instrumentation.recordDecrypt()
        return try custodian.withKey { raw in
            let dek = try SecureBytes(zeroed: raw.count)
            dek.withUnsafeMutableBytes { dst in
                dst.baseAddress!.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            let paddedLen = try ChunkObject.open(
                stored: stored, declaredChunkSize: e.chunkSize,
                into: buffer, dek: dek,
                galleryID: galleryID, fileID: e.aadFileID,
                chunkIndex: index, epoch: e.epoch)
            try ChunkGeometry.validatePadding(
                chunk: buffer, paddedLen: paddedLen, index: index,
                unpaddedLength: e.unpaddedLength, chunkSize: e.chunkSize)
            return Int(
                ChunkGeometry.unpaddedLength(
                    ofChunk: index, unpaddedLength: e.unpaddedLength, chunkSize: e.chunkSize))
        }
    }
}

import Foundation

/// Plaintext-plane RANGE reader for streaming playback (CED-12 WS
/// A.3): serves arbitrary byte ranges of an entry by pulling sealed
/// chunk objects through a `SealedChunkProvider` and decrypting them
/// into a shared `ResidentChunkCache` under the residency budget.
///
/// Division of verification labor (Codex Q1 disposition):
///  - CAS-address verification happens AT THE SEAM — the fetched
///    bytes are re-hashed here on every cache miss, so ANY provider
///    (local, fake, future remote) is held to the address contract;
///  - AEAD + padding verification stays HERE, on the plaintext plane
///    (exactly where `ChunkReader` does it) — never in a provider.
///
/// Custody: every decrypt runs under the custodian's read custody
/// (`lock()` revokes it — reads fail closed with `vaultLocked`);
/// resident plaintext lives in the cache's `SecureBytes` entries.
/// The `Data` this reader RETURNS is ordinary heap — the documented
/// residual class the loader hands to AVFoundation (CED-12 Q3
/// honest-boundary rule).
public final class StreamingReader: Sendable {
    let galleryID: UUID
    let custodian: KeyCustodian
    let entries: [InventoryEntry]
    let provider: any SealedChunkProvider
    let cache: ResidentChunkCache
    let instrumentation: ReaderInstrumentation

    init(
        galleryID: UUID, custodian: KeyCustodian, entries: [InventoryEntry],
        provider: any SealedChunkProvider, cache: ResidentChunkCache,
        instrumentation: ReaderInstrumentation = ReaderInstrumentation()
    ) {
        self.galleryID = galleryID
        self.custodian = custodian
        self.entries = entries
        self.provider = provider
        self.cache = cache
        self.instrumentation = instrumentation
    }

    private func entry(for fileID: FileID) throws -> InventoryEntry {
        guard let e = entries.first(where: { $0.fileID == fileID }) else {
            throw VaultError.fileNotFound(fileID)
        }
        return e
    }

    /// Unpadded length of `fileID` (the loader's contentLength).
    public func contentLength(of fileID: FileID) throws -> UInt64 {
        try entry(for: fileID).unpaddedLength
    }

    /// Per-file chunk size (the loader's per-respond slice bound).
    public func chunkSize(of fileID: FileID) throws -> UInt32 {
        try entry(for: fileID).chunkSize
    }

    /// Decrypt-count probe (benchmark + custody gates).
    public var decryptCount: Int { instrumentation.decryptCount }

    /// Reads `offset..<offset+length` of `fileID` into ordinary-heap
    /// `Data`, touching only the chunks the range overlaps
    /// (padding-aware range→chunk math is pinned by the WS A tests).
    /// Fails closed (`vaultLocked`) after lock; propagates
    /// `chunkUnavailable` / `budgetExhausted` typed so the loader can
    /// distinguish loader failure from AEAD damage.
    public func readRange(fileID: FileID, offset: UInt64, length: Int) async throws -> Data {
        let e = try entry(for: fileID)
        // Overflow-safe bounds check (same shape as ChunkReader's —
        // offset is caller-supplied).
        guard length > 0, offset <= e.unpaddedLength,
            UInt64(length) <= e.unpaddedLength - offset
        else {
            throw VaultError.rangeOutOfBounds
        }
        var out = Data(capacity: length)
        let chunkSize = UInt64(e.chunkSize)
        let firstChunk = offset / chunkSize
        let lastChunk = (offset + UInt64(length) - 1) / chunkSize
        var written = 0
        for index in firstChunk...lastChunk {
            try Task.checkCancellation()
            let chunkStart = index * chunkSize
            let sliceStart = index == firstChunk ? Int(offset - chunkStart) : 0
            let remaining = length - written
            let part: Data = try await withResidentChunk(e, index: index) {
                buffer, contentLength in
                let n = min(contentLength - sliceStart, remaining)
                guard n > 0 else { throw VaultError.lengthMismatch }
                return Data(
                    bytes: buffer.baseAddress!.advanced(by: sliceStart), count: n)
            }
            out.append(part)
            written += part.count
        }
        guard written == length else { throw VaultError.lengthMismatch }
        return out
    }

    /// Serves chunk `index` of `entry` from the cache, running the
    /// full miss path (provider fetch → seam address check → AEAD
    /// open → padding validation) when needed.
    private func withResidentChunk<R: Sendable>(
        _ e: InventoryEntry, index: UInt64,
        _ body: @Sendable (UnsafeRawBufferPointer, _ contentLength: Int) throws -> R
    ) async throws -> R {
        let address = e.chunkAddresses[Int(index)]
        let paddedLen = ChunkGeometry.paddedLength(
            ofChunk: index, unpaddedLength: e.unpaddedLength, chunkSize: e.chunkSize)
        let provider = self.provider
        let custodian = self.custodian
        let galleryID = self.galleryID
        let instrumentation = self.instrumentation
        let aadFileID = e.aadFileID
        let epoch = e.epoch
        let declaredChunkSize = e.chunkSize
        let unpaddedLength = e.unpaddedLength
        return try await cache.withChunk(
            address: address, cost: paddedLen,
            fetchAndDecrypt: {
                let stored = try await provider.fetchChunk(address)
                // Seam address check: hold every provider to the CAS
                // contract before a single AEAD cycle runs.
                let actual = ChunkAddress.compute(over: stored)
                guard actual == address else {
                    throw VaultError.addressMismatch(expected: address, actual: actual)
                }
                // The decrypt buffer is sized to the EXPECTED padded
                // length, so an oversized stored object must be
                // refused before the AEAD write, not discovered by
                // the guard page.
                let expectedStored =
                    ChunkObject.headerLength + paddedLen + CryptoCore.aeadTagBytes
                guard stored.count == expectedStored else {
                    throw VaultError.lengthMismatch
                }
                let buffer = try SecureBytes(zeroed: paddedLen)
                instrumentation.recordDecrypt()
                let openedLen = try custodian.withKey { raw in
                    try ChunkObject.open(
                        stored: stored, declaredChunkSize: declaredChunkSize,
                        into: buffer, rawDEK: raw,
                        galleryID: galleryID, fileID: aadFileID,
                        chunkIndex: index, epoch: epoch)
                }
                try ChunkGeometry.validatePadding(
                    chunk: buffer, paddedLen: openedLen, index: index,
                    unpaddedLength: unpaddedLength, chunkSize: declaredChunkSize)
                let contentLen = Int(
                    ChunkGeometry.unpaddedLength(
                        ofChunk: index, unpaddedLength: unpaddedLength,
                        chunkSize: declaredChunkSize))
                return DecryptedChunk(bytes: buffer, contentLength: contentLen)
            },
            body)
    }
}


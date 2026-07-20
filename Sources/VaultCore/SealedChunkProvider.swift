import Foundation

/// Sealed-plane source of stored chunk objects, addressed by
/// `ChunkAddress` (CED-12 WS A.1). This is the read-path seam the
/// playback engine streams through — and the seam a future sync leg
/// implements with a remote fetch. Deliberately NOT `ChunkSource`:
/// that name belongs to the move-only sequential import source in
/// `Gallery.swift`, which ingests plaintext; this protocol serves
/// SEALED bytes only (the background-sealed-transfer-only principle).
///
/// Contract (pinned by `SealedChunkProviderContractTests`):
///  - `fetchChunk` returns the FULL stored object bytes (header ‖
///    ciphertext) for `address`, and MUST verify the bytes hash to
///    the requested address before returning (`addressMismatch`
///    otherwise) — CAS-address verification lives at this seam.
///    AEAD verification does NOT: that stays with the plaintext-plane
///    reader that decrypts (`StreamingReader` / `ChunkReader`).
///  - A chunk the provider cannot produce throws
///    `chunkUnavailable(address:retryable:)`. No suspension or retry
///    machinery exists at this seam; `retryable` is a report, not a
///    promise the provider will deliver later.
public protocol SealedChunkProvider: Sendable {
    /// Fetches (and address-verifies) the stored chunk object bytes
    /// for `address`.
    func fetchChunk(_ address: ChunkAddress) async throws -> [UInt8]
}

/// The one real provider this leg: reads the gallery's own `chunks/`
/// CAS directory. Missing files are permanently unavailable
/// (`retryable: false`) — the local CAS has no "not yet downloaded"
/// state.
public struct LocalChunkStore: SealedChunkProvider {
    let layout: VaultLayout

    public func fetchChunk(_ address: ChunkAddress) async throws -> [UInt8] {
        let url = layout.chunkURL(address)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.chunkUnavailable(address, retryable: false)
        }
        let bytes = try FS.read(
            url, object: .chunk, maxBytes: SealedVault.maxStoredChunkBytes)
        let actual = ChunkAddress.compute(over: bytes)
        guard actual == address else {
            throw VaultError.addressMismatch(expected: address, actual: actual)
        }
        return bytes
    }
}

extension SealedVault {
    /// Sealed-plane chunk provider over this vault's own CAS.
    public func makeChunkProvider() -> LocalChunkStore {
        LocalChunkStore(layout: layout)
    }
}

import Foundation

/// A stored chunk object (format v0):
///   magic(8) ‖ version u16 ‖ nonce(24) ‖ ciphertext(plaintext+16 tag)
/// The nonce is RANDOM per chunk (Codex B1 — deliberately superseding
/// intake §5.3's deterministic derivation). Position binding comes from
/// the AAD (gallery, file, index, epoch, version — Codex B3), so a
/// validly-tagged chunk cannot be substituted at another position.
enum ChunkObject {
    static let headerLength = 8 + 2 + CryptoCore.aeadNonceBytes  // 34

    /// Seals one padded chunk plaintext into a stored object. Returns
    /// the full stored bytes (header ‖ ciphertext).
    static func seal(
        plaintext: borrowing SecureBytes,
        plaintextLen: Int,
        dek: borrowing SecureBytes,
        galleryID: UUID,
        fileID: FileID,
        chunkIndex: UInt64,
        epoch: UInt32
    ) throws -> [UInt8] {
        let nonce = try CryptoCore.randomBytes(CryptoCore.aeadNonceBytes)
        var w = WireWriter()
        w.raw(FormatV0.chunkMagic)
        w.u16(FormatV0.version)
        w.raw(nonce)
        let ciphertext = CryptoCore.aeadSeal(
            plaintext: plaintext, plaintextLen: plaintextLen,
            key: dek, nonce: nonce,
            aad: FormatV0.chunkAAD(
                galleryID: galleryID, fileID: fileID, chunkIndex: chunkIndex, epoch: epoch))
        w.raw(ciphertext)
        return w.bytes
    }

    struct Header {
        let nonce: ArraySlice<UInt8>
        let ciphertext: ArraySlice<UInt8>
    }

    /// Structurally parses a stored object; bounds-checks lengths
    /// against the declared chunk size before any allocation.
    static func parseHeader(_ stored: [UInt8], declaredChunkSize: UInt32) throws -> Header {
        var r = WireReader(stored, object: .chunk)
        try r.expectMagic(FormatV0.chunkMagic)
        let version = try r.u16()
        guard version == FormatV0.version else {
            throw VaultError.unsupportedFormatVersion(.chunk, found: version)
        }
        let nonce = try r.take(CryptoCore.aeadNonceBytes)
        let ciphertextLen = r.remaining
        let plaintextLen = ciphertextLen - CryptoCore.aeadTagBytes
        guard plaintextLen >= Int(FormatV0.paddingBoundary),
            plaintextLen <= Int(declaredChunkSize),
            plaintextLen % Int(FormatV0.paddingBoundary) == 0
        else {
            throw VaultError.boundsViolation(.chunk, field: "ciphertext_length")
        }
        let ciphertext = try r.take(ciphertextLen)
        return Header(nonce: nonce, ciphertext: ciphertext)
    }

    /// Opens a stored chunk into caller-provided secure memory,
    /// verifying the AEAD tag and the positional AAD. Returns the
    /// padded plaintext length. Takes the DEK as RAW bytes so readers
    /// decrypt against the custodian's live allocation (drain-on-lock
    /// force-zero then genuinely revokes in-flight reads).
    static func open(
        stored: [UInt8],
        declaredChunkSize: UInt32,
        into plaintext: borrowing SecureBytes,
        rawDEK: UnsafeRawBufferPointer,
        galleryID: UUID,
        fileID: FileID,
        chunkIndex: UInt64,
        epoch: UInt32
    ) throws -> Int {
        let header = try parseHeader(stored, declaredChunkSize: declaredChunkSize)
        return try CryptoCore.aeadOpen(
            ciphertext: header.ciphertext,
            into: plaintext,
            rawKey: rawDEK,
            nonce: header.nonce,
            aad: FormatV0.chunkAAD(
                galleryID: galleryID, fileID: fileID, chunkIndex: chunkIndex, epoch: epoch),
            object: .chunk)
    }
}

/// Chunk/padding geometry (Codex B10, grill Q12). Every stored chunk
/// plaintext is a multiple of the 64 KiB padding boundary: non-tail
/// chunks are exactly `chunkSize`; the tail pads up with zero bytes.
/// A zero-byte file is one fully-padded chunk (never zero chunks), so
/// empty files carry no unique fingerprint.
enum ChunkGeometry {
    static func validate(chunkSize: UInt32) throws {
        guard chunkSize >= FormatV0.minChunkSize,
            chunkSize <= FormatV0.maxChunkSize,
            chunkSize % FormatV0.paddingBoundary == 0
        else {
            throw VaultError.boundsViolation(.inventory, field: "chunk_size")
        }
    }

    /// Number of chunks for a file of `unpaddedLength` bytes.
    static func chunkCount(unpaddedLength: UInt64, chunkSize: UInt32) -> UInt64 {
        guard unpaddedLength > 0 else { return 1 }
        return (unpaddedLength + UInt64(chunkSize) - 1) / UInt64(chunkSize)
    }

    /// Unpadded plaintext bytes carried by chunk `index`.
    static func unpaddedLength(ofChunk index: UInt64, unpaddedLength: UInt64, chunkSize: UInt32)
        -> UInt64
    {
        let count = chunkCount(unpaddedLength: unpaddedLength, chunkSize: chunkSize)
        precondition(index < count)
        if index < count - 1 { return UInt64(chunkSize) }
        return unpaddedLength - index * UInt64(chunkSize)
    }

    /// Stored (padded) plaintext length of chunk `index`: the unpadded
    /// tail rounded up to the padding boundary, minimum one boundary.
    static func paddedLength(ofChunk index: UInt64, unpaddedLength: UInt64, chunkSize: UInt32)
        -> Int
    {
        let raw = ChunkGeometry.unpaddedLength(
            ofChunk: index, unpaddedLength: unpaddedLength, chunkSize: chunkSize)
        let boundary = UInt64(FormatV0.paddingBoundary)
        let padded = max(boundary, (raw + boundary - 1) / boundary * boundary)
        return Int(padded)
    }

    /// Validates a decrypted chunk against the entry's declared
    /// lengths: padded length must match exactly, and every pad byte
    /// must be zero (docs/formats.md §Padding).
    static func validatePadding(
        chunk: borrowing SecureBytes,
        paddedLen: Int,
        index: UInt64,
        unpaddedLength: UInt64,
        chunkSize: UInt32
    ) throws {
        let expectedPadded = paddedLength(
            ofChunk: index, unpaddedLength: unpaddedLength, chunkSize: chunkSize)
        guard paddedLen == expectedPadded else { throw VaultError.lengthMismatch }
        let content = Int(
            ChunkGeometry.unpaddedLength(
                ofChunk: index, unpaddedLength: unpaddedLength, chunkSize: chunkSize))
        guard paddedLen >= content else { throw VaultError.lengthMismatch }
        let ok = chunk.withUnsafeBytes { raw -> Bool in
            for i in content..<paddedLen where raw[i] != 0 { return false }
            return true
        }
        guard ok else { throw VaultError.paddingInvalid }
    }
}

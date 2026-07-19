import Clibsodium
import Foundation

/// One file entry in the local encrypted inventory (format-version 0,
/// Codex B9). Explicitly a LOCAL artifact: the Manifest-CRDT leg
/// supersedes this with the durable signed-entry format; the object's
/// version field makes that migration detectable. No signed entries,
/// tombstones, or merge logic here.
struct InventoryEntry: Equatable {
    let fileID: FileID
    /// The file ID baked into the chunks' AEAD associated data. Equal
    /// to `fileID` for a first import; for a dedup re-import it is the
    /// ORIGINAL entry's `aadFileID`, because shared chunks stay bound
    /// to the context they were sealed under (chunk AAD includes the
    /// sealing file ID — Codex B3 — so sharing requires remembering it).
    let aadFileID: FileID
    /// Keyring epoch whose DEK encrypted this file's chunks.
    let epoch: UInt32
    /// Per-file chunk size (Codex A8): bounded, boundary-aligned.
    let chunkSize: UInt32
    /// True (unpadded) file length in bytes. AEAD-protected here and
    /// validated against chunk contents on read (Codex B10).
    let unpaddedLength: UInt64
    /// BLAKE2b-256 over (dedup domain prefix ‖ plaintext). Lives only
    /// inside this encrypted object (Codex A4); never in snapshots.
    let dedupHash: [UInt8]
    let chunkAddresses: [ChunkAddress]
    /// Opaque app-provided metadata blob. VaultCore treats it as
    /// ciphertext-opaque; session-scoped accessors return it (Codex B6).
    let metadata: [UInt8]
}

/// The decrypted inventory: generation counter + entries. Generation
/// increases by exactly 1 per committed mutation and is what HEAD
/// recovery uses to pick the newest reachable inventory.
struct Inventory: Equatable {
    var generation: UInt64
    var entries: [InventoryEntry]

    static let empty = Inventory(generation: 0, entries: [])

    func entry(for fileID: FileID) throws -> InventoryEntry {
        guard let e = entries.first(where: { $0.fileID == fileID }) else {
            throw VaultError.fileNotFound(fileID)
        }
        return e
    }

    // -- plaintext body codec (docs/formats.md §Inventory body) --

    func serializeBody() -> [UInt8] {
        var w = WireWriter()
        w.u64(generation)
        w.u32(UInt32(entries.count))
        for e in entries {
            w.raw(e.fileID.wireBytes)
            w.raw(e.aadFileID.wireBytes)
            w.u32(e.epoch)
            w.u32(e.chunkSize)
            w.u64(e.unpaddedLength)
            w.raw(e.dedupHash)
            w.u32(UInt32(e.chunkAddresses.count))
            for a in e.chunkAddresses { w.raw(a.bytes) }
            w.u32(UInt32(e.metadata.count))
            w.raw(e.metadata)
        }
        return w.bytes
    }

    static func parseBody(_ bytes: [UInt8]) throws -> Inventory {
        var r = WireReader(bytes, object: .inventory)
        let generation = try r.u64()
        let entryCount = try r.u32()
        guard entryCount <= FormatV0.maxInventoryEntries else {
            throw VaultError.boundsViolation(.inventory, field: "entry_count")
        }
        var entries: [InventoryEntry] = []
        entries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            let fileID = FileID(uuid: try UUID(wireBytes: r.take(16)))
            let aadFileID = FileID(uuid: try UUID(wireBytes: r.take(16)))
            let epoch = try r.u32()
            let chunkSize = try r.u32()
            try ChunkGeometry.validate(chunkSize: chunkSize)
            let unpaddedLength = try r.u64()
            // Bounded like every other declared length (wave-002 #2):
            // also keeps the chunk-count arithmetic below overflow-free.
            guard unpaddedLength <= FormatV0.maxFileBytes else {
                throw VaultError.boundsViolation(.inventory, field: "unpadded_length")
            }
            let dedupHash = Array(try r.take(CryptoCore.hashBytes))
            let chunkCount = try r.u32()
            let expected = ChunkGeometry.chunkCount(
                unpaddedLength: unpaddedLength, chunkSize: chunkSize)
            guard UInt64(chunkCount) == expected else {
                throw VaultError.boundsViolation(.inventory, field: "chunk_count")
            }
            var addresses: [ChunkAddress] = []
            addresses.reserveCapacity(Int(chunkCount))
            for _ in 0..<chunkCount {
                guard let a = ChunkAddress(bytes: Array(try r.take(CryptoCore.hashBytes))) else {
                    throw VaultError.truncatedObject(.inventory)
                }
                addresses.append(a)
            }
            let metadataLen = try r.u32()
            guard metadataLen <= FormatV0.maxMetadataBlobBytes else {
                throw VaultError.boundsViolation(.inventory, field: "metadata_length")
            }
            let metadata = Array(try r.take(Int(metadataLen)))
            guard !entries.contains(where: { $0.fileID == fileID }) else {
                throw VaultError.boundsViolation(.inventory, field: "duplicate_file_id")
            }
            entries.append(
                InventoryEntry(
                    fileID: fileID, aadFileID: aadFileID, epoch: epoch, chunkSize: chunkSize,
                    unpaddedLength: unpaddedLength, dedupHash: dedupHash,
                    chunkAddresses: addresses, metadata: metadata))
        }
        try r.expectExhausted()
        return Inventory(generation: generation, entries: entries)
    }

    // -- stored object codec --
    // magic(8) ‖ version u16 ‖ nonce(24) ‖ ciphertext(body + 16 tag)

    /// Seals this inventory into a stored object under the DEK.
    func sealObject(dek: borrowing SecureBytes, galleryID: UUID, epoch: UInt32) throws -> [UInt8] {
        let body = serializeBody()
        let buf = try SecureBytes(zeroed: max(body.count, 1))
        buf.withUnsafeMutableBytes { raw in
            body.withUnsafeBufferPointer { src in
                if let b = src.baseAddress, src.count > 0 {
                    raw.baseAddress!.copyMemory(from: b, byteCount: src.count)
                }
            }
        }
        let nonce = try CryptoCore.randomBytes(CryptoCore.aeadNonceBytes)
        var w = WireWriter()
        w.raw(FormatV0.inventoryMagic)
        w.u16(FormatV0.version)
        w.raw(nonce)
        w.raw(
            CryptoCore.aeadSeal(
                plaintext: buf, plaintextLen: body.count,
                key: dek, nonce: nonce,
                aad: FormatV0.inventoryAAD(galleryID: galleryID, epoch: epoch)))
        return w.bytes
    }

    /// Opens a stored inventory object. Structural checks are cheap and
    /// bounded before the AEAD pass; the body parse re-validates every
    /// field bound. Raw DEK bytes for the same drain-revocation reason
    /// as `ChunkObject.open`.
    static func openObject(
        stored: [UInt8], rawDEK: UnsafeRawBufferPointer, galleryID: UUID, epoch: UInt32
    ) throws -> Inventory {
        guard stored.count <= FormatV0.maxInventoryObjectBytes else {
            throw VaultError.boundsViolation(.inventory, field: "object_length")
        }
        var r = WireReader(stored, object: .inventory)
        try r.expectMagic(FormatV0.inventoryMagic)
        let version = try r.u16()
        guard version == FormatV0.version else {
            throw VaultError.unsupportedFormatVersion(.inventory, found: version)
        }
        let nonce = try r.take(CryptoCore.aeadNonceBytes)
        guard r.remaining >= CryptoCore.aeadTagBytes else {
            throw VaultError.truncatedObject(.inventory)
        }
        let ciphertext = try r.take(r.remaining)
        let plain = try SecureBytes(zeroed: ciphertext.count - CryptoCore.aeadTagBytes + 1)
        let n = try CryptoCore.aeadOpen(
            ciphertext: ciphertext, into: plain, rawKey: rawDEK, nonce: nonce,
            aad: FormatV0.inventoryAAD(galleryID: galleryID, epoch: epoch),
            object: .inventory)
        // The body parses into ordinary memory: structural data plus
        // the app's opaque metadata blobs. NOTE the custody trade,
        // recorded in docs/formats.md §Security notes: metadata blob
        // BYTES live in ordinary heap for the session's lifetime —
        // lock() revokes ACCESS (accessors fail closed) but does not
        // wipe those arrays. Content plaintext never flows through
        // the inventory. The transient body copy is zeroed below.
        var body = plain.withUnsafeBytes { raw in
            Array(UnsafeRawBufferPointer(rebasing: raw[0..<n]))
        }
        defer {
            body.withUnsafeMutableBufferPointer { p in
                if let base = p.baseAddress { sodium_memzero(base, p.count) }
            }
        }
        return try parseBody(body)
    }
}

/// HEAD (format v0): magic(8) ‖ version u16 ‖ address(32). Points at
/// the current inventory object under `manifest/`. Swapped atomically
/// (write temp, fsync, rename, fsync dir) as the commit point.
enum Head {
    static let length = 8 + 2 + CryptoCore.hashBytes

    static func serialize(_ address: ChunkAddress) -> [UInt8] {
        var w = WireWriter()
        w.raw(FormatV0.headMagic)
        w.u16(FormatV0.version)
        w.raw(address.bytes)
        return w.bytes
    }

    static func parse(_ bytes: [UInt8]) throws -> ChunkAddress {
        guard bytes.count == length else { throw VaultError.corruptHead }
        var r = WireReader(bytes, object: .head)
        do {
            try r.expectMagic(FormatV0.headMagic)
            let version = try r.u16()
            guard version == FormatV0.version else { throw VaultError.corruptHead }
            guard let a = ChunkAddress(bytes: Array(try r.take(CryptoCore.hashBytes))) else {
                throw VaultError.corruptHead
            }
            return a
        } catch {
            throw VaultError.corruptHead
        }
    }
}

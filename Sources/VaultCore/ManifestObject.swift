import Clibsodium
import Foundation

/// The stored v1 manifest object (GOAL WS B.5): ONE complete encrypted
/// operation-set snapshot — trust list, signed entries, signed
/// tombstones — content-addressed in `manifest/` exactly like the v0
/// inventory, with HEAD naming exactly one.
///
/// `localRevision` is the v0 generation counter's survivor (review
/// Q5): +1 per committed local mutation, feeding `snapshotStream` and
/// recovery's highest-valid-local-generation rule. It is a LOCAL
/// commit revision — persisted here for recovery, but NOT part of the
/// CRDT, never merged, never compared across devices (documented in
/// docs/formats.md).
struct ManifestObject: Equatable, Sendable {
    var localRevision: UInt64
    var state: ManifestState

    // -- plaintext body codec (docs/formats.md §Manifest body v1) --

    func serializeBody() -> [UInt8] {
        var w = WireWriter()
        w.u64(localRevision)
        state.trustList.serialize(into: &w)
        w.u32(UInt32(state.entries.count))
        for e in state.entries { e.serialize(into: &w) }
        w.u32(UInt32(state.tombstones.count))
        for t in state.tombstones { t.serialize(into: &w) }
        return w.bytes
    }

    static func parseBody(_ bytes: [UInt8]) throws -> ManifestObject {
        var r = WireReader(bytes, object: .manifest)
        let localRevision = try r.u64()
        let trustList = try SignedTrustList.parse(&r)
        let entryCount = try r.u32()
        guard entryCount <= FormatV1.maxManifestEntries else {
            throw VaultError.boundsViolation(.manifest, field: "entry_count")
        }
        var entries: [SignedAddEntry] = []
        entries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            let e = try SignedAddEntry.parse(&r)
            // Canonical order: strictly ascending file IDs — exactly
            // one representation, duplicate identities impossible.
            if let last = entries.last,
                !last.fileID.wireBytes.lexicographicallyPrecedes(e.fileID.wireBytes)
            {
                throw VaultError.boundsViolation(.manifest, field: "entry_order")
            }
            entries.append(e)
        }
        let tombstoneCount = try r.u32()
        guard tombstoneCount <= FormatV1.maxTombstones else {
            throw VaultError.boundsViolation(.manifest, field: "tombstone_count")
        }
        var tombstones: [SignedTombstone] = []
        tombstones.reserveCapacity(Int(tombstoneCount))
        for _ in 0..<tombstoneCount {
            let t = try SignedTombstone.parse(&r)
            if let last = tombstones.last,
                !last.storedBytes.lexicographicallyPrecedes(t.storedBytes)
            {
                throw VaultError.boundsViolation(.manifest, field: "tombstone_order")
            }
            tombstones.append(t)
        }
        try r.expectExhausted()
        return ManifestObject(
            localRevision: localRevision,
            state: ManifestState(trustList: trustList, entries: entries, tombstones: tombstones))
    }

    // -- stored object codec --
    // magic(8) ‖ version u16 ‖ nonce(24) ‖ ciphertext(body + 16 tag)

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
        w.raw(FormatV1.manifestMagic)
        w.u16(FormatV1.version)
        w.raw(nonce)
        w.raw(
            CryptoCore.aeadSeal(
                plaintext: buf, plaintextLen: body.count,
                key: dek, nonce: nonce,
                aad: FormatV1.manifestAAD(galleryID: galleryID, epoch: epoch)))
        return w.bytes
    }

    /// Opens a stored manifest object: structural checks → AEAD →
    /// canonical body parse. Signature verification is the CALLER'S
    /// next step (`state.verifySignatures`), per the normative order.
    static func openObject(
        stored: [UInt8], rawDEK: UnsafeRawBufferPointer, galleryID: UUID, epoch: UInt32
    ) throws -> ManifestObject {
        guard stored.count <= FormatV1.maxManifestObjectBytes else {
            throw VaultError.boundsViolation(.manifest, field: "object_length")
        }
        var r = WireReader(stored, object: .manifest)
        try r.expectMagic(FormatV1.manifestMagic)
        let version = try r.u16()
        guard version == FormatV1.version else {
            throw VaultError.unsupportedFormatVersion(.manifest, found: version)
        }
        let nonce = try r.take(CryptoCore.aeadNonceBytes)
        guard r.remaining >= CryptoCore.aeadTagBytes else {
            throw VaultError.truncatedObject(.manifest)
        }
        let ciphertext = try r.take(r.remaining)
        let plain = try SecureBytes(zeroed: ciphertext.count - CryptoCore.aeadTagBytes + 1)
        let n = try CryptoCore.aeadOpen(
            ciphertext: ciphertext, into: plain, rawKey: rawDEK, nonce: nonce,
            aad: FormatV1.manifestAAD(galleryID: galleryID, epoch: epoch),
            object: .manifest)
        // Same custody trade as the v0 inventory (docs/formats.md
        // §Security notes): the parsed structural body and metadata
        // blobs live in ordinary heap; the transient body copy is
        // zeroed below.
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

/// The signed HEAD descriptor (GOAL WS B.7): binds the manifest
/// address to the writing device and its per-device monotonic counter.
/// The rollback detector compares the counter against the device-local
/// high-water mark for KNOWN signers.
struct SignedHeadDescriptor: Equatable, Sendable {
    let manifestAddress: ChunkAddress
    let devicePublicKey: DevicePublicKey
    let counter: UInt64
    let signature: [UInt8]

    static func payloadBytes(
        manifestAddress: ChunkAddress, device: DevicePublicKey, counter: UInt64
    ) -> [UInt8] {
        var w = WireWriter()
        w.raw(manifestAddress.bytes)
        w.raw(device.bytes)
        w.u64(counter)
        return w.bytes
    }

    var payloadBytes: [UInt8] {
        Self.payloadBytes(
            manifestAddress: manifestAddress, device: devicePublicKey, counter: counter)
    }

    static func minted(
        manifestAddress: ChunkAddress, counter: UInt64, author: DeviceIdentity, galleryID: UUID
    ) -> SignedHeadDescriptor {
        let payload = payloadBytes(
            manifestAddress: manifestAddress, device: author.publicKey, counter: counter)
        let signature = author.sign(
            FormatV1.signingBytes(
                domain: FormatV1.headSigDomain, galleryID: galleryID, payload: payload))
        return SignedHeadDescriptor(
            manifestAddress: manifestAddress, devicePublicKey: author.publicKey,
            counter: counter, signature: signature)
    }

    func verify(galleryID: UUID) throws {
        let message = FormatV1.signingBytes(
            domain: FormatV1.headSigDomain, galleryID: galleryID, payload: payloadBytes)
        guard DeviceIdentity.verify(
            signature: signature, message: message, publicKey: devicePublicKey)
        else {
            throw VaultError.signatureInvalid(.head)
        }
    }
}

/// HEAD (format v1), fixed 218 bytes:
/// `MSVHEAD1` ‖ version u16 ‖ manifest_address(32) ‖ nonce(24) ‖
/// sealed descriptor ciphertext(136 + 16 tag).
///
/// The manifest address stays PLAINTEXT (the sealed plane must resolve
/// HEAD without the DEK, exactly as in v0); the signed descriptor —
/// device public key and counter, the rollback-detection material — is
/// AEAD-sealed so device identities never appear in cleartext on disk.
enum HeadV1 {
    static let descriptorPlaintextLength =
        CryptoCore.hashBytes + DevicePublicKey.byteCount + 8 + DeviceIdentity.signatureBytes  // 136
    static let length =
        8 + 2 + CryptoCore.hashBytes + CryptoCore.aeadNonceBytes
        + descriptorPlaintextLength + CryptoCore.aeadTagBytes  // 218

    static func serialize(
        descriptor: SignedHeadDescriptor, dek: borrowing SecureBytes,
        galleryID: UUID, epoch: UInt32
    ) throws -> [UInt8] {
        let plainBytes = descriptor.payloadBytes + descriptor.signature
        precondition(plainBytes.count == descriptorPlaintextLength)
        let buf = try SecureBytes(zeroed: plainBytes.count)
        buf.withUnsafeMutableBytes { raw in
            plainBytes.withUnsafeBufferPointer { src in
                raw.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        let nonce = try CryptoCore.randomBytes(CryptoCore.aeadNonceBytes)
        var w = WireWriter()
        w.raw(FormatV1.headMagic)
        w.u16(FormatV1.version)
        w.raw(descriptor.manifestAddress.bytes)
        w.raw(nonce)
        w.raw(
            CryptoCore.aeadSeal(
                plaintext: buf, plaintextLen: plainBytes.count,
                key: dek, nonce: nonce,
                aad: FormatV1.headAAD(galleryID: galleryID, epoch: epoch)))
        precondition(w.bytes.count == length)
        return w.bytes
    }

    /// Sealed-plane parse: address only, no DEK.
    static func parseAddress(_ bytes: [UInt8]) throws -> ChunkAddress {
        guard bytes.count == length else { throw VaultError.corruptHead }
        var r = WireReader(bytes, object: .head)
        do {
            try r.expectMagic(FormatV1.headMagic)
            let version = try r.u16()
            guard version == FormatV1.version else { throw VaultError.corruptHead }
            guard let a = ChunkAddress(bytes: Array(try r.take(CryptoCore.hashBytes))) else {
                throw VaultError.corruptHead
            }
            return a
        } catch {
            throw VaultError.corruptHead
        }
    }

    /// Opens and signature-verifies the sealed descriptor, and checks
    /// that its inner manifest address equals the plaintext one — a
    /// spliced HEAD (valid descriptor from one commit, plaintext
    /// address from another) fails here.
    static func openDescriptor(
        _ bytes: [UInt8], rawDEK: UnsafeRawBufferPointer, galleryID: UUID, epoch: UInt32
    ) throws -> SignedHeadDescriptor {
        let plainAddress = try parseAddress(bytes)
        var r = WireReader(bytes, object: .head)
        _ = try r.take(8 + 2 + CryptoCore.hashBytes)
        let nonce = try r.take(CryptoCore.aeadNonceBytes)
        let ciphertext = try r.take(r.remaining)
        let plain = try SecureBytes(zeroed: descriptorPlaintextLength)
        let n = try CryptoCore.aeadOpen(
            ciphertext: ciphertext, into: plain, rawKey: rawDEK, nonce: nonce,
            aad: FormatV1.headAAD(galleryID: galleryID, epoch: epoch),
            object: .head)
        guard n == descriptorPlaintextLength else { throw VaultError.corruptHead }
        let descriptorBytes = plain.withUnsafeBytes { raw in
            Array(UnsafeRawBufferPointer(rebasing: raw[0..<n]))
        }
        var d = WireReader(descriptorBytes, object: .head)
        guard let address = ChunkAddress(bytes: Array(try d.take(CryptoCore.hashBytes))),
            let device = DevicePublicKey(bytes: Array(try d.take(DevicePublicKey.byteCount)))
        else { throw VaultError.corruptHead }
        let counter = try d.u64()
        let signature = Array(try d.take(DeviceIdentity.signatureBytes))
        try d.expectExhausted()
        let descriptor = SignedHeadDescriptor(
            manifestAddress: address, devicePublicKey: device,
            counter: counter, signature: signature)
        try descriptor.verify(galleryID: galleryID)
        guard address == plainAddress else {
            throw VaultError.signatureInvalid(.head)
        }
        return descriptor
    }
}

/// Version dispatch over the HEAD file: v0 (42-byte plaintext pointer)
/// and v1 (218-byte pointer + sealed signed descriptor) coexist during
/// migration — the HEAD version IS the vault's manifest format marker.
enum HeadFile {
    enum Parsed: Equatable {
        case v0(ChunkAddress)
        case v1(ChunkAddress)

        var address: ChunkAddress {
            switch self {
            case .v0(let a), .v1(let a): return a
            }
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> Parsed {
        if bytes.count == Head.length {
            return .v0(try Head.parse(bytes))
        }
        if bytes.count == HeadV1.length {
            return .v1(try HeadV1.parseAddress(bytes))
        }
        throw VaultError.corruptHead
    }
}

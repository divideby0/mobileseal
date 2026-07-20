import Foundation

/// A device's recorded role. Format v1 RECORDS roles but does not yet
/// enforce multi-party authority: every device in the trust list
/// belongs to the vault owner (single-user semantics, GOAL scope
/// note); the full author-or-owner rule gains force at the sharing
/// legs.
public enum DeviceRole: UInt8, Sendable, Equatable, Comparable {
    case owner = 1
    case member = 2

    public static func < (a: DeviceRole, b: DeviceRole) -> Bool { a.rawValue < b.rawValue }
}

/// One device in the trust list (GOAL WS A.2).
public struct TrustedDevice: Equatable, Sendable {
    public let publicKey: DevicePublicKey
    public let role: DeviceRole
    /// Wall-clock registration time, unix milliseconds. Recorded for
    /// display; never used in merge ordering (the CRDT has no clocks).
    public let addedAtUnixMS: UInt64
    /// Human-readable device name, UTF-8, ≤ 256 bytes.
    public let name: String

    init(publicKey: DevicePublicKey, role: DeviceRole, addedAtUnixMS: UInt64, name: String) {
        self.publicKey = publicKey
        self.role = role
        self.addedAtUnixMS = addedAtUnixMS
        self.name = name
    }
}

/// The signed, versioned device registry (GOAL WS A.2): an append-only
/// device-set union this leg (no removal — revocation is a sharing-leg
/// concern). Genesis is created at gallery creation/migration, signed
/// by the creating device; new devices self-register on first
/// write-capable unlock (TOFU). The signer MUST itself be listed —
/// TOFU-honest circularity, documented: gallery-password possession IS
/// authorization in single-user semantics.
struct SignedTrustList: Equatable, Sendable {
    /// Monotonic list version: each committed update increments past
    /// the highest version it has seen.
    let listVersion: UInt64
    /// Sorted strictly ascending by public key bytes (canonical form).
    let devices: [TrustedDevice]
    let signerPublicKey: DevicePublicKey
    let signature: [UInt8]

    func device(for key: DevicePublicKey) -> TrustedDevice? {
        devices.first(where: { $0.publicKey == key })
    }

    func contains(_ key: DevicePublicKey) -> Bool {
        device(for: key) != nil
    }

    // -- canonical codec --

    static func payloadBytes(listVersion: UInt64, devices: [TrustedDevice], signer: DevicePublicKey)
        -> [UInt8]
    {
        var w = WireWriter()
        w.u64(listVersion)
        w.u32(UInt32(devices.count))
        for d in devices {
            w.raw(d.publicKey.bytes)
            w.u8(d.role.rawValue)
            w.u64(d.addedAtUnixMS)
            let name = Array(d.name.utf8)
            w.u16(UInt16(name.count))
            w.raw(name)
        }
        w.raw(signer.bytes)
        return w.bytes
    }

    var payloadBytes: [UInt8] {
        Self.payloadBytes(listVersion: listVersion, devices: devices, signer: signerPublicKey)
    }

    /// Mints a signed trust list. Devices are canonicalized (sorted by
    /// public key); duplicates are a programmer error.
    static func minted(
        listVersion: UInt64, devices: [TrustedDevice], signer: DeviceIdentity, galleryID: UUID
    ) -> SignedTrustList {
        let sorted = devices.sorted { $0.publicKey.bytes.lexicographicallyPrecedes($1.publicKey.bytes) }
        precondition(
            Set(sorted.map(\.publicKey)).count == sorted.count,
            "duplicate device in trust list")
        precondition(sorted.contains { $0.publicKey == signer.publicKey },
            "trust-list signer must be listed")
        let payload = payloadBytes(
            listVersion: listVersion, devices: sorted, signer: signer.publicKey)
        let signature = signer.sign(
            FormatV1.signingBytes(
                domain: FormatV1.trustListSigDomain, galleryID: galleryID, payload: payload))
        return SignedTrustList(
            listVersion: listVersion, devices: sorted,
            signerPublicKey: signer.publicKey, signature: signature)
    }

    func serialize(into w: inout WireWriter) {
        w.raw(payloadBytes)
        w.raw(signature)
    }

    /// Structural parse only — canonical-form violations (unsorted or
    /// duplicate devices, bounds, bad enums) reject here. Signature
    /// verification is the SEPARATE, later step (`verifySignature`),
    /// per the normative order decrypt → parse → verify.
    static func parse(_ r: inout WireReader) throws -> SignedTrustList {
        let listVersion = try r.u64()
        let count = try r.u32()
        guard count >= 1, count <= FormatV1.maxTrustedDevices else {
            throw VaultError.boundsViolation(.manifest, field: "trust_device_count")
        }
        var devices: [TrustedDevice] = []
        devices.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let pk = DevicePublicKey(bytes: Array(try r.take(DevicePublicKey.byteCount)))
            else { throw VaultError.truncatedObject(.manifest) }
            guard let role = DeviceRole(rawValue: try r.u8()) else {
                throw VaultError.boundsViolation(.manifest, field: "device_role")
            }
            let addedAt = try r.u64()
            let nameLen = try r.u16()
            guard Int(nameLen) <= FormatV1.maxDeviceNameBytes else {
                throw VaultError.boundsViolation(.manifest, field: "device_name_length")
            }
            let nameBytes = Array(try r.take(Int(nameLen)))
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                Array(name.utf8) == nameBytes
            else {
                throw VaultError.boundsViolation(.manifest, field: "device_name_utf8")
            }
            // Canonical order: strictly ascending public keys — one
            // representation per logical list, duplicates impossible.
            if let last = devices.last,
                !last.publicKey.bytes.lexicographicallyPrecedes(pk.bytes)
            {
                throw VaultError.boundsViolation(.manifest, field: "trust_device_order")
            }
            devices.append(
                TrustedDevice(publicKey: pk, role: role, addedAtUnixMS: addedAt, name: name))
        }
        guard let signer = DevicePublicKey(bytes: Array(try r.take(DevicePublicKey.byteCount)))
        else { throw VaultError.truncatedObject(.manifest) }
        let signature = Array(try r.take(DeviceIdentity.signatureBytes))
        return SignedTrustList(
            listVersion: listVersion, devices: devices,
            signerPublicKey: signer, signature: signature)
    }

    /// Signature + signer-membership verification. The signer must be
    /// a device the list itself names (TOFU root, documented).
    func verify(galleryID: UUID) throws {
        guard contains(signerPublicKey) else {
            throw VaultError.untrustedSigner(.trustList)
        }
        let message = FormatV1.signingBytes(
            domain: FormatV1.trustListSigDomain, galleryID: galleryID, payload: payloadBytes)
        guard DeviceIdentity.verify(
            signature: signature, message: message, publicKey: signerPublicKey)
        else {
            throw VaultError.signatureInvalid(.trustList)
        }
    }

    /// Append-only union merge of two device sets (GOAL WS A.2): same
    /// public key merges field-wise deterministically (min role — owner
    /// wins, min added-at, lexicographically smaller name), so merge is
    /// commutative and associative regardless of encounter order.
    static func mergeDevices(_ a: [TrustedDevice], _ b: [TrustedDevice]) -> [TrustedDevice] {
        var byKey: [DevicePublicKey: TrustedDevice] = [:]
        for d in a + b {
            if let existing = byKey[d.publicKey] {
                byKey[d.publicKey] = TrustedDevice(
                    publicKey: d.publicKey,
                    role: min(existing.role, d.role),
                    addedAtUnixMS: min(existing.addedAtUnixMS, d.addedAtUnixMS),
                    name: [existing.name, d.name].min()!)
            } else {
                byKey[d.publicKey] = d
            }
        }
        return byKey.values.sorted {
            $0.publicKey.bytes.lexicographicallyPrecedes($1.publicKey.bytes)
        }
    }
}

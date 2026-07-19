import Foundation

/// Argon2id cost parameters, stored per gallery in `gallery.meta`.
/// Defaults follow research/_default/argon2id-tuning-on-modern-iphones.md
/// (libsodium MODERATE: opslimit 3, memlimit 256 MiB).
public struct KDFParams: Sendable, Equatable {
    public let opslimit: UInt32
    public let memlimit: UInt64

    public static let `default` = KDFParams(opslimit: 3, memlimit: 256 * 1024 * 1024)

    public init(opslimit: UInt32, memlimit: UInt64) {
        self.opslimit = opslimit
        self.memlimit = memlimit
    }

    /// Hard bounds check (Codex B13). Runs before ANY KDF allocation so
    /// a tampered gallery.meta cannot DoS the device. Floors also
    /// reject absurdly weak parameters.
    func validate() throws {
        guard (FormatV0.minOpslimit...FormatV0.maxOpslimit).contains(opslimit) else {
            throw VaultError.kdfParamsOutOfBounds(field: "opslimit")
        }
        guard (FormatV0.minMemlimit...FormatV0.maxMemlimit).contains(memlimit) else {
            throw VaultError.kdfParamsOutOfBounds(field: "memlimit")
        }
    }
}

/// One wrapped-DEK entry in the epoch keyring (Codex B4): the DEK
/// wrapped under the password-derived KEK with XChaCha20-Poly1305.
struct KeyringEntry: Equatable {
    let epoch: UInt32
    let nonce: [UInt8]  // 24 bytes, random per wrap
    let wrappedDEK: [UInt8]  // 48 bytes: 32 ciphertext + 16 tag
}

/// Parsed `gallery.meta` (format v0): structural information only —
/// nothing here requires (or yields) the DEK. See docs/formats.md
/// §gallery.meta for the byte layout.
public struct GalleryMeta: Sendable {
    public let galleryID: UUID
    public let kdfParams: KDFParams
    public let salt: [UInt8]  // 16 bytes
    /// Epochs present in the keyring, ascending. Today: [0].
    public let epochs: [UInt32]
    let keyring: [KeyringEntry]

    /// The current (highest) epoch — the one new content encrypts under.
    public var currentEpoch: UInt32 { epochs.max() ?? 0 }

    func entry(forEpoch epoch: UInt32) throws -> KeyringEntry {
        guard let e = keyring.first(where: { $0.epoch == epoch }) else {
            throw VaultError.unknownEpoch(epoch)
        }
        return e
    }

    static func parse(_ bytes: [UInt8]) throws -> GalleryMeta {
        var r = WireReader(bytes, object: .galleryMeta)
        try r.expectMagic(FormatV0.metaMagic)
        let version = try r.u16()
        guard version == FormatV0.version else {
            throw VaultError.unsupportedFormatVersion(.galleryMeta, found: version)
        }
        let galleryID = try UUID(wireBytes: r.take(16))
        let kdfAlg = try r.u8()
        guard kdfAlg == 1 else {
            throw VaultError.boundsViolation(.galleryMeta, field: "kdf_alg")
        }
        let opslimit = try r.u32()
        let memlimit = try r.u64()
        let params = KDFParams(opslimit: opslimit, memlimit: memlimit)
        try params.validate()  // before anything can allocate
        let salt = Array(try r.take(CryptoCore.saltBytes))
        let entryCount = try r.u16()
        guard entryCount >= 1, Int(entryCount) <= FormatV0.maxKeyringEntries else {
            throw VaultError.boundsViolation(.galleryMeta, field: "keyring_entry_count")
        }
        var keyring: [KeyringEntry] = []
        keyring.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            let epoch = try r.u32()
            let nonce = Array(try r.take(CryptoCore.aeadNonceBytes))
            let wrappedLen = try r.u16()
            guard Int(wrappedLen) == FormatV0.wrappedDEKLength else {
                throw VaultError.boundsViolation(.galleryMeta, field: "wrapped_dek_length")
            }
            let wrapped = Array(try r.take(Int(wrappedLen)))
            guard !keyring.contains(where: { $0.epoch == epoch }) else {
                throw VaultError.boundsViolation(.galleryMeta, field: "duplicate_epoch")
            }
            keyring.append(KeyringEntry(epoch: epoch, nonce: nonce, wrappedDEK: wrapped))
        }
        try r.expectExhausted()
        return GalleryMeta(
            galleryID: galleryID,
            kdfParams: params,
            salt: salt,
            epochs: keyring.map(\.epoch).sorted(),
            keyring: keyring)
    }

    static func serialize(
        galleryID: UUID, kdfParams: KDFParams, salt: [UInt8], keyring: [KeyringEntry]
    ) -> [UInt8] {
        var w = WireWriter()
        w.raw(FormatV0.metaMagic)
        w.u16(FormatV0.version)
        w.raw(galleryID.wireBytes)
        w.u8(1)  // kdf_alg: Argon2id13
        w.u32(kdfParams.opslimit)
        w.u64(kdfParams.memlimit)
        w.raw(salt)
        w.u16(UInt16(keyring.count))
        for e in keyring {
            w.u32(e.epoch)
            w.raw(e.nonce)
            w.u16(UInt16(e.wrappedDEK.count))
            w.raw(e.wrappedDEK)
        }
        return w.bytes
    }

    /// Unwraps the DEK for `epoch` with the given password. Wrong
    /// password and tampered keyring entry are indistinguishable —
    /// both throw `.dekUnwrapFailed`.
    func unwrapDEK(password: borrowing SecureBytes, epoch: UInt32) throws -> SecureBytes {
        let entry = try entry(forEpoch: epoch)
        let kek = try CryptoCore.deriveKEK(
            password: password, salt: salt,
            opslimit: kdfParams.opslimit, memlimit: kdfParams.memlimit)
        let dek = try SecureBytes(zeroed: CryptoCore.keyBytes)
        do {
            let n = try CryptoCore.aeadOpen(
                ciphertext: entry.wrappedDEK[...],
                into: dek,
                key: kek,
                nonce: entry.nonce[...],
                aad: FormatV0.dekWrapAAD(galleryID: galleryID, epoch: epoch),
                object: .galleryMeta)
            guard n == CryptoCore.keyBytes else { throw VaultError.dekUnwrapFailed }
        } catch {
            throw VaultError.dekUnwrapFailed
        }
        return dek
    }

    /// Wraps `dek` under the password-derived KEK for `epoch`.
    static func wrapDEK(
        dek: borrowing SecureBytes,
        password: borrowing SecureBytes,
        galleryID: UUID,
        salt: [UInt8],
        kdfParams: KDFParams,
        epoch: UInt32
    ) throws -> KeyringEntry {
        let kek = try CryptoCore.deriveKEK(
            password: password, salt: salt,
            opslimit: kdfParams.opslimit, memlimit: kdfParams.memlimit)
        let nonce = try CryptoCore.randomBytes(CryptoCore.aeadNonceBytes)
        let wrapped = CryptoCore.aeadSeal(
            plaintext: dek, plaintextLen: CryptoCore.keyBytes,
            key: kek, nonce: nonce,
            aad: FormatV0.dekWrapAAD(galleryID: galleryID, epoch: epoch))
        return KeyringEntry(epoch: epoch, nonce: nonce, wrappedDEK: wrapped)
    }
}

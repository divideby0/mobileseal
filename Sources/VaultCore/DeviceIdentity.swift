import Clibsodium
import Foundation

/// A device's Ed25519 public signing key (32 bytes). Value identity for
/// trust lists, authorship checks, and rollback high-water keying.
public struct DevicePublicKey: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = Int(crypto_sign_PUBLICKEYBYTES)  // 32

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    public var hex: String { Hex.encode(bytes) }
    public var description: String { hex }
}

/// This device's Ed25519 signing identity (GOAL WS A.1). A class so the
/// move-only secret key has stable custody while the identity is shared
/// between the unlock session and the gallery actor (the `KeyLease`
/// pattern); the secure allocation zeroes on deinit. The secret key has
/// NO public accessor — signing is the only operation that touches it,
/// and the compile-fail harness pins that raw key bytes cannot escape.
public final class DeviceIdentity: @unchecked Sendable {
    public static let secretKeyBytes = Int(crypto_sign_SECRETKEYBYTES)  // 64
    public static let signatureBytes = Int(crypto_sign_BYTES)  // 64

    public let publicKey: DevicePublicKey
    private let secretKey: SecureBytes

    /// Takes custody of a 64-byte libsodium Ed25519 secret key. The
    /// public key is DERIVED from the secret key, never trusted from
    /// the caller — a store returning a mismatched pair would otherwise
    /// mint signatures the recorded identity cannot verify.
    public init(consuming secretKey: consuming SecureBytes) throws {
        try SodiumRuntime.ensure()
        guard secretKey.count == Self.secretKeyBytes else {
            let count = secretKey.count
            secretKey.zeroAndFree()
            throw VaultError.deviceIdentityInvalid(
                reason: "secret key must be \(Self.secretKeyBytes) bytes, got \(count)")
        }
        var pk = [UInt8](repeating: 0, count: DevicePublicKey.byteCount)
        let rc = secretKey.withUnsafeBytes { sk in
            crypto_sign_ed25519_sk_to_pk(
                &pk, sk.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard rc == 0, let publicKey = DevicePublicKey(bytes: pk) else {
            secretKey.zeroAndFree()
            throw VaultError.deviceIdentityInvalid(reason: "public key derivation failed")
        }
        self.publicKey = publicKey
        self.secretKey = secretKey
    }

    /// Generates a fresh Ed25519 keypair in secure memory.
    public static func generate() throws -> DeviceIdentity {
        try SodiumRuntime.ensure()
        let sk = try SecureBytes(zeroed: secretKeyBytes)
        var pk = [UInt8](repeating: 0, count: DevicePublicKey.byteCount)
        let rc = sk.withUnsafeMutableBytes { skRaw in
            crypto_sign_keypair(&pk, skRaw.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard rc == 0 else {
            sk.zeroAndFree()
            throw VaultError.secureMemoryUnavailable
        }
        return try DeviceIdentity(consuming: sk)
    }

    /// Detached Ed25519 signature over `message`. The one place secret
    /// key bytes are read; the pointer never escapes the closure.
    func sign(_ message: [UInt8]) -> [UInt8] {
        var signature = [UInt8](repeating: 0, count: Self.signatureBytes)
        var len: UInt64 = 0
        let rc = secretKey.withUnsafeBytes { sk in
            crypto_sign_detached(
                &signature, &len, message, UInt64(message.count),
                sk.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        precondition(rc == 0 && Int(len) == Self.signatureBytes, "detached signing cannot fail")
        return signature
    }

    /// Detached Ed25519 verification (no secret material involved).
    static func verify(signature: [UInt8], message: [UInt8], publicKey: DevicePublicKey) -> Bool {
        guard signature.count == signatureBytes else { return false }
        return crypto_sign_verify_detached(
            signature, message, UInt64(message.count), publicKey.bytes) == 0
    }
}

/// Pluggable custody for this device's signing identity (GOAL WS A.1).
/// The reference app implements it over the iOS Keychain
/// (`WhenUnlockedThisDeviceOnly`, device-bound); the CLI leg adds a
/// passphrase-wrapped file variant. VaultCore sees only this protocol
/// and `SecureBytes` — never raw key `Data`.
public protocol DeviceKeyStore: Sendable {
    /// Returns this device's identity, creating and persisting a fresh
    /// keypair on first use. MUST be idempotent: a second call returns
    /// the same identity (the migration state machine re-runs it).
    func loadOrCreateIdentity() throws -> DeviceIdentity
}

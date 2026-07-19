import Clibsodium
import Foundation

/// Thin, allocation-conscious wrappers over the exact libsodium
/// primitives format v0 commits to (docs/formats.md §Algorithms):
///   AEAD  crypto_aead_xchacha20poly1305_ietf (24-byte nonce, 16-byte tag)
///   KDF   crypto_pwhash, alg ARGON2ID13
///   Hash  crypto_generichash (BLAKE2b), 32-byte digest
/// Key material only ever lives in `SecureBytes`; decryption writes
/// plaintext directly into caller-provided secure memory.
enum CryptoCore {
    static let aeadNonceBytes = Int(crypto_aead_xchacha20poly1305_ietf_NPUBBYTES)  // 24
    static let aeadTagBytes = Int(crypto_aead_xchacha20poly1305_ietf_ABYTES)  // 16
    static let keyBytes = Int(crypto_aead_xchacha20poly1305_ietf_KEYBYTES)  // 32
    static let saltBytes = Int(crypto_pwhash_SALTBYTES)  // 16
    static let hashBytes = 32

    static func randomBytes(_ count: Int) throws -> [UInt8] {
        try SodiumRuntime.ensure()
        var out = [UInt8](repeating: 0, count: count)
        randombytes_buf(&out, count)
        return out
    }

    /// BLAKE2b-256 over plain (non-secret) bytes.
    static func blake2b256(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: hashBytes)
        crypto_generichash(&out, hashBytes, input, UInt64(input.count), nil, 0)
        return out
    }

    /// Streaming BLAKE2b-256 (used for whole-file dedup hashing without
    /// holding the file in memory). The state struct is opaque through
    /// the binary Clibsodium module, so it lives in a manually managed
    /// allocation sized by `crypto_generichash_statebytes()`.
    final class Blake2bStream {
        private let state: UnsafeMutableRawPointer

        init(domain: [UInt8] = []) {
            state = .allocate(byteCount: crypto_generichash_statebytes(), alignment: 64)
            crypto_generichash_init(OpaquePointer(state), nil, 0, CryptoCore.hashBytes)
            if !domain.isEmpty {
                crypto_generichash_update(OpaquePointer(state), domain, UInt64(domain.count))
            }
        }

        func update(_ bytes: ArraySlice<UInt8>) {
            bytes.withUnsafeBufferPointer { p in
                _ = crypto_generichash_update(OpaquePointer(state), p.baseAddress, UInt64(p.count))
            }
        }

        func update(secure bytes: borrowing SecureBytes, count: Int) {
            bytes.withUnsafeBytes { raw in
                _ = crypto_generichash_update(
                    OpaquePointer(state), raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt64(count))
            }
        }

        func finalize() -> [UInt8] {
            var out = [UInt8](repeating: 0, count: CryptoCore.hashBytes)
            crypto_generichash_final(OpaquePointer(state), &out, CryptoCore.hashBytes)
            return out
        }

        deinit { state.deallocate() }
    }

    /// AEAD-seal `plaintext` (secure memory) into a fresh ciphertext
    /// array (ciphertext is not secret). Returns `plaintextLen + 16`.
    static func aeadSeal(
        plaintext: borrowing SecureBytes,
        plaintextLen: Int,
        key: borrowing SecureBytes,
        nonce: [UInt8],
        aad: [UInt8]
    ) -> [UInt8] {
        precondition(nonce.count == aeadNonceBytes)
        precondition(plaintextLen <= plaintext.count)
        var ciphertext = [UInt8](repeating: 0, count: plaintextLen + aeadTagBytes)
        var clen: UInt64 = 0
        let rc = plaintext.withUnsafeBytes { p in
            key.withUnsafeBytes { k in
                crypto_aead_xchacha20poly1305_ietf_encrypt(
                    &ciphertext, &clen,
                    p.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt64(plaintextLen),
                    aad, UInt64(aad.count),
                    nil, nonce, k.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        precondition(rc == 0, "AEAD encryption cannot fail with valid arguments")
        return ciphertext
    }

    /// AEAD-open `ciphertext` directly into caller-provided secure
    /// memory (no intermediate Data/array plaintext copy — spike S4).
    /// Returns the plaintext length, or throws on tag failure.
    static func aeadOpen(
        ciphertext: ArraySlice<UInt8>,
        into plaintext: borrowing SecureBytes,
        key: borrowing SecureBytes,
        nonce: ArraySlice<UInt8>,
        aad: [UInt8],
        object: VaultObjectKind
    ) throws -> Int {
        guard ciphertext.count >= aeadTagBytes,
            plaintext.count >= ciphertext.count - aeadTagBytes
        else { throw VaultError.truncatedObject(object) }
        var mlen: UInt64 = 0
        let rc = plaintext.withUnsafeMutableBytes { m in
            key.withUnsafeBytes { k in
                ciphertext.withUnsafeBufferPointer { c in
                    Array(nonce).withUnsafeBufferPointer { n in
                        crypto_aead_xchacha20poly1305_ietf_decrypt(
                            m.baseAddress!.assumingMemoryBound(to: UInt8.self), &mlen,
                            nil,
                            c.baseAddress!, UInt64(c.count),
                            aad, UInt64(aad.count),
                            n.baseAddress!, k.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    }
                }
            }
        }
        guard rc == 0 else { throw VaultError.authenticationFailed(object) }
        return Int(mlen)
    }

    /// Argon2id KDF (alg ARGON2ID13). Parameters must already be
    /// bounds-validated (`KDFParams.validate()`) — this function
    /// allocates `memlimit` bytes.
    static func deriveKEK(
        password: borrowing SecureBytes,
        salt: [UInt8],
        opslimit: UInt32,
        memlimit: UInt64
    ) throws -> SecureBytes {
        precondition(salt.count == saltBytes)
        let kek = try SecureBytes(zeroed: keyBytes)
        let rc = kek.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                crypto_pwhash(
                    out.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt64(keyBytes),
                    pw.baseAddress!.assumingMemoryBound(to: CChar.self), UInt64(pw.count),
                    salt,
                    UInt64(opslimit), Int(memlimit),
                    crypto_pwhash_ALG_ARGON2ID13)
            }
        }
        guard rc == 0 else {
            // crypto_pwhash fails only on resource exhaustion.
            throw VaultError.secureMemoryUnavailable
        }
        return kek
    }
}

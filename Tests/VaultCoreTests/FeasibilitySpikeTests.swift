import Clibsodium
import Foundation
import Testing

// CED-10 Workstream A.2 feasibility spike (Codex B7).
//
// Proves, on the pinned toolchain (Apple Swift 6.2), that the move-only
// API shapes VaultCore's public surface needs actually compile and run:
//
//   S1. A `~Copyable` sodium_malloc-backed buffer with deinit zeroing,
//       scoped borrowing access, and a consuming end-of-life operation.
//   S2. A `~Copyable` session type with a `consuming func lock()` and a
//       scoped `(borrowing …) -> R` plaintext closure.
//   S3. The session shape interoperating with an actor: the actor holds
//       a reference-typed custodian, the move-only session stays in the
//       caller's isolation, and off-actor Sendable readers work.
//   S4. Swift-Sodium's Clibsodium module decrypting AEAD ciphertext
//       DIRECTLY into sodium_malloc memory — no intermediate `Data` or
//       `[UInt8]` plaintext copy.
//
// Outcome (recorded in results/RESULT.md): native move-only types are
// feasible; the class-based-custody fallback is NOT needed.

private struct SpikeSecureBytes: ~Copyable {
    private let ptr: UnsafeMutableRawPointer
    let count: Int

    init?(count: Int) {
        // sodium_init is idempotent and thread-safe; sodium_malloc's
        // guard-canary requires it to have run first.
        guard sodium_init() >= 0 else { return nil }
        guard count > 0, let p = sodium_malloc(count) else { return nil }
        ptr = p
        self.count = count
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: ptr, count: count))
    }

    consuming func zeroAndFree() {
        sodium_free(ptr)  // sodium_free zeroes the region before unmapping
        discard self
    }

    deinit {
        sodium_free(ptr)
    }
}

private struct SpikeSession: ~Copyable {
    let custodian: SpikeCustodian

    consuming func lock() {
        custodian.zero()
        // no deinit on this type: consuming ends the lifetime here
    }

    func withPlaintext<R>(_ body: (borrowing SpikeSecureBytes) throws -> R) rethrows -> R? {
        guard let buf = SpikeSecureBytes(count: 4) else { return nil }
        defer { /* buf deinit zeroes */ }
        return try body(buf)
    }
}

private final class SpikeCustodian: @unchecked Sendable {
    private let lock = NSLock()
    private var zeroed = false
    func zero() {
        lock.lock()
        zeroed = true
        lock.unlock()
    }
    var isZeroed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return zeroed
    }
}

private actor SpikeGallery {
    let custodian: SpikeCustodian
    init(custodian: SpikeCustodian) { self.custodian = custodian }
    func mutate() -> Int { 42 }
}

@Suite struct FeasibilitySpike {
    @Test func s1_secureBytesScopedAccessAndConsume() {
        var probe = [UInt8](repeating: 0, count: 4)
        let buf = SpikeSecureBytes(count: 4)!
        buf.withUnsafeMutableBytes { raw in
            raw.copyBytes(from: [1, 2, 3, 4])
        }
        buf.withUnsafeBytes { raw in
            probe = Array(raw)
        }
        #expect(probe == [1, 2, 3, 4])
        buf.zeroAndFree()
        // `buf` is consumed here; any further use is a compile error
        // (regression-locked by the compile-fail harness).
    }

    @Test func s2_s3_moveOnlySessionAcrossActorShapes() async {
        let custodian = SpikeCustodian()
        let session = SpikeSession(custodian: custodian)
        let gallery = SpikeGallery(custodian: custodian)

        let out = session.withPlaintext { bytes -> Int in
            bytes.count
        }
        #expect(out == 4)

        let n = await gallery.mutate()
        #expect(n == 42)

        session.lock()
        #expect(custodian.isZeroed)
    }

    @Test func s4_clibsodiumDecryptsIntoSodiumMalloc() {
        #expect(sodium_init() >= 0)

        let keyLen = Int(crypto_aead_xchacha20poly1305_ietf_KEYBYTES)
        let nonceLen = Int(crypto_aead_xchacha20poly1305_ietf_NPUBBYTES)
        let tagLen = Int(crypto_aead_xchacha20poly1305_ietf_ABYTES)

        var key = [UInt8](repeating: 0, count: keyLen)
        var nonce = [UInt8](repeating: 0, count: nonceLen)
        randombytes_buf(&key, keyLen)
        randombytes_buf(&nonce, nonceLen)

        let message = [UInt8]("spike plaintext".utf8)
        var ciphertext = [UInt8](repeating: 0, count: message.count + tagLen)
        var clen: UInt64 = 0
        let encRC = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &clen,
            message, UInt64(message.count),
            nil, 0, nil, nonce, key
        )
        #expect(encRC == 0)

        // Decrypt directly into guarded sodium_malloc memory: the
        // plaintext pointer handed to libsodium IS the secure buffer.
        let plainBuf = SpikeSecureBytes(count: message.count)!
        var mlen: UInt64 = 0
        let decRC = plainBuf.withUnsafeMutableBytes { raw in
            crypto_aead_xchacha20poly1305_ietf_decrypt(
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self), &mlen,
                nil,
                ciphertext, clen,
                nil, 0, nonce, key
            )
        }
        #expect(decRC == 0)
        #expect(mlen == UInt64(message.count))
        let roundTripped = plainBuf.withUnsafeBytes { Array($0) }
        #expect(roundTripped == message)
        plainBuf.zeroAndFree()
    }
}

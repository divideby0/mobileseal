import Clibsodium
import Foundation

/// Sole holder of the unwrapped DEK. Implements drain-on-lock (Codex
/// B5): `lockAndDrain` refuses new reads immediately, waits up to the
/// deadline for in-flight reads to finish, then zeroes the key. The key
/// allocation is reference-held for the duration of each read — a read
/// either completes against the intact key or fails closed with
/// `VaultError.vaultLocked`; after the drain deadline the key is zeroed
/// even if a straggler is mid-decrypt, in which case its AEAD tag check
/// fails and the read still surfaces `vaultLocked` (never plaintext).
final class KeyCustodian: @unchecked Sendable {
    private let cond = NSCondition()
    // Guarded by `cond`:
    private var locked = false
    private var activeReads = 0
    private var zeroed = false
    /// 32-byte sodium_malloc'd DEK. Freed only in deinit; zeroed at lock
    /// so no reader can ever dereference freed memory.
    private let key: UnsafeMutableRawPointer

    /// Takes custody of `dek`, moving it into this custodian's own
    /// guarded allocation and consuming (zeroing) the source.
    init(consuming dek: consuming SecureBytes) throws {
        try SodiumRuntime.ensure()
        guard let p = sodium_malloc(CryptoCore.keyBytes) else {
            throw VaultError.secureMemoryUnavailable
        }
        dek.withUnsafeBytes { src in
            p.copyMemory(from: src.baseAddress!, byteCount: CryptoCore.keyBytes)
        }
        dek.zeroAndFree()
        self.key = p
    }

    var isLocked: Bool {
        cond.lock()
        defer { cond.unlock() }
        return locked
    }

    /// Runs `body` with the DEK under read custody. Throws
    /// `vaultLocked` if the vault is locked or draining. If the drain
    /// deadline force-zeroes the key mid-`body`, the AEAD failure the
    /// body inevitably hits is remapped to `vaultLocked` by `remap`.
    func withKey<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        cond.lock()
        guard !locked else {
            cond.unlock()
            throw VaultError.vaultLocked
        }
        activeReads += 1
        cond.unlock()
        defer {
            cond.lock()
            activeReads -= 1
            cond.broadcast()
            cond.unlock()
        }
        do {
            return try body(UnsafeRawBufferPointer(start: key, count: CryptoCore.keyBytes))
        } catch let error as VaultError {
            // A read that raced the force-zero sees an authentication
            // failure caused by the zeroed key — report the true cause.
            cond.lock()
            let lostRace = locked
            cond.unlock()
            if lostRace, case .authenticationFailed = error {
                throw VaultError.vaultLocked
            }
            throw error
        }
    }

    /// Returns a scoped secure-memory copy of the DEK, taken under
    /// momentary read custody (throws `vaultLocked` when locked). For
    /// call shapes where a borrowing closure cannot be used (e.g.
    /// actor-isolated code capturing move-only buffers).
    func keyCopy() throws -> SecureBytes {
        let copy = try SecureBytes(zeroed: CryptoCore.keyBytes)
        try withKey { raw in
            copy.withUnsafeMutableBytes { dst in
                dst.baseAddress!.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
        return copy
    }

    /// Lock: refuse new reads now; wait up to `drainDeadline` seconds
    /// for in-flight reads; then zero the DEK unconditionally.
    func lockAndDrain(drainDeadline: TimeInterval) {
        cond.lock()
        guard !locked else {
            cond.unlock()
            return
        }
        locked = true  // new reads refused from this instant
        let limit = Date().addingTimeInterval(drainDeadline)
        while activeReads > 0, cond.wait(until: limit) {}
        // Drained — or deadline passed with stragglers; zero either way.
        sodium_memzero(key, CryptoCore.keyBytes)
        zeroed = true
        cond.unlock()
    }

    /// Test hook (green gate 5): provably zeroed after drain.
    var debugKeyIsZeroed: Bool {
        cond.lock()
        defer { cond.unlock() }
        guard zeroed else { return false }
        let bytes = UnsafeRawBufferPointer(start: key, count: CryptoCore.keyBytes)
        return bytes.allSatisfy { $0 == 0 }
    }

    deinit {
        sodium_free(key)
    }
}

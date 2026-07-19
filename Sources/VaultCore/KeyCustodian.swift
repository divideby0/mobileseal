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
    private var writerClaimed = false
    private var claimedVaultPath: String?
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

    /// Leases a secure-memory copy of the DEK for call shapes where a
    /// borrowing closure cannot be used (actor-isolated code capturing
    /// move-only buffers). The lease COUNTS AS AN ACTIVE READ until it
    /// deinitializes, so `lockAndDrain` waits for outstanding leases
    /// the same way it waits for in-flight `withKey` reads (wave-001
    /// claude-code #5: a bare copy escaped drain custody). Past the
    /// drain deadline the custodian's own allocation is force-zeroed;
    /// a straggling lease's copy zeroes at its deinit, and any commit
    /// it attempts is refused by the post-lock check.
    func leaseKey() throws -> KeyLease {
        let copy = try SecureBytes(zeroed: CryptoCore.keyBytes)
        cond.lock()
        guard !locked else {
            cond.unlock()
            copy.zeroAndFree()
            throw VaultError.vaultLocked
        }
        activeReads += 1
        cond.unlock()
        copy.withUnsafeMutableBytes { dst in
            dst.baseAddress!.copyMemory(from: key, byteCount: CryptoCore.keyBytes)
        }
        return KeyLease(custodian: self, key: copy)
    }

    fileprivate func endLease() {
        cond.lock()
        activeReads -= 1
        cond.broadcast()
        cond.unlock()
    }

    /// One-shot writer claim, scoped to the VAULT DIRECTORY across all
    /// sessions in this process — not just this custodian (wave-001
    /// claude-code #2; hardened per the wave-003 blocker, where a
    /// second `unlock()` minted a second writer and silently lost a
    /// committed import). The process-wide claim is released when this
    /// custodian locks or deinitializes.
    func claimWriter(vaultPath: String) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        guard !writerClaimed else { return false }
        guard VaultProcessRegistry.shared.claimWriter(path: vaultPath) else {
            return false
        }
        writerClaimed = true
        claimedVaultPath = vaultPath
        return true
    }

    private func releaseWriterClaimLocked() {
        if let path = claimedVaultPath {
            VaultProcessRegistry.shared.releaseWriter(path: path)
            claimedVaultPath = nil
        }
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
        releaseWriterClaimLocked()
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
        // A custodian dropped without an explicit lock (session went
        // out of scope) still releases the process-wide writer claim.
        releaseWriterClaimLocked()
        sodium_free(key)
    }
}

/// A drained-awaited DEK copy (see `KeyCustodian.leaseKey`). Class so
/// deinit reliably releases the read count; the secure copy zeroes on
/// its own deinit.
final class KeyLease {
    private let custodian: KeyCustodian
    private let key: SecureBytes

    fileprivate init(custodian: KeyCustodian, key: consuming SecureBytes) {
        self.custodian = custodian
        self.key = key
    }

    func withKey<R>(_ body: (borrowing SecureBytes) throws -> R) rethrows -> R {
        try body(key)
    }

    deinit {
        custodian.endLease()
    }
}

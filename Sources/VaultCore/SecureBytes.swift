import Clibsodium
import Foundation

/// Ensures libsodium is initialized exactly once before any use.
/// `sodium_malloc`'s guard canary is seeded by `sodium_init`; calling it
/// lazily from an arbitrary thread first would abort the process.
enum SodiumRuntime {
    private static let initialized: Bool = sodium_init() >= 0

    /// mlock failure policy (Codex Q7): best-effort. libsodium already
    /// attempts mlock inside sodium_malloc; when the platform refuses
    /// (common under iOS memory limits) we log once and proceed —
    /// guarded allocation (canaries + zero-on-free) is still in force.
    static func ensure() throws {
        guard initialized else { throw VaultError.secureMemoryUnavailable }
    }
}

/// A move-only, libsodium-guarded byte buffer for key material and
/// decrypted plaintext. Backed by `sodium_malloc` (guard pages, canary,
/// best-effort mlock); zeroed and unmapped on deinit. Copying is a
/// compile error; plaintext leaves only through scoped closures.
public struct SecureBytes: ~Copyable {
    @usableFromInline
    let ptr: UnsafeMutableRawPointer
    public let count: Int

    /// Allocates a zero-filled secure buffer.
    /// - Throws: `VaultError.secureMemoryUnavailable` when libsodium
    ///   cannot provide guarded memory (`sodium_malloc` failure aborts
    ///   the operation that needed it — never a plain-memory fallback).
    public init(zeroed count: Int) throws {
        try SodiumRuntime.ensure()
        precondition(count > 0, "SecureBytes requires a positive size")
        guard let p = sodium_malloc(count) else {
            throw VaultError.secureMemoryUnavailable
        }
        sodium_memzero(p, count)
        self.ptr = p
        self.count = count
    }

    /// Copies `source` into secure memory, then zeroes `source` in
    /// place so the only remaining copy is the guarded one. Empty
    /// input is refused: no call site has a legitimate empty secret,
    /// and padding an empty buffer to one zero byte would collide ""
    /// with "\0" as KDF input (wave-002 claude-code #3).
    public init(consumingAndZeroing source: inout [UInt8]) throws {
        guard !source.isEmpty else { throw VaultError.emptyPassword }
        try self.init(zeroed: source.count)
        source.withUnsafeBufferPointer { src in
            if let base = src.baseAddress, src.count > 0 {
                ptr.copyMemory(from: base, byteCount: src.count)
            }
        }
        source.withUnsafeMutableBufferPointer { src in
            if let base = src.baseAddress, src.count > 0 {
                sodium_memzero(base, src.count)
            }
        }
    }

    /// NFC-normalizes the password and copies its UTF-8 bytes into
    /// secure memory (Codex A5). VaultCore never RETAINS a `String`,
    /// but be honest about the residual: normalization itself
    /// allocates a transient `String` in ordinary heap whose storage
    /// is deallocated unwiped (documented in docs/formats.md
    /// §Security notes). Callers who can supply already-normalized
    /// bytes should use `init(consumingAndZeroing:)` directly. Empty
    /// passwords are refused: the secure buffer's minimum size is one
    /// byte, and "" colliding with "\0" would be a silent KEK
    /// collision (wave-001 #13).
    public init(nfcNormalizedPassword password: String) throws {
        guard !password.isEmpty else { throw VaultError.emptyPassword }
        var bytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        try self.init(consumingAndZeroing: &bytes)
    }

    /// Scoped read access. The pointer must not escape `body`.
    @inlinable
    public func withUnsafeBytes<R, E: Error>(
        _ body: (UnsafeRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        try body(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    /// Scoped write access. The pointer must not escape `body`.
    @inlinable
    public func withUnsafeMutableBytes<R, E: Error>(
        _ body: (UnsafeMutableRawBufferPointer) throws(E) -> R
    ) throws(E) -> R {
        try body(UnsafeMutableRawBufferPointer(start: ptr, count: count))
    }

    /// Constant-time equality against a plain byte array (for tests and
    /// tag comparisons; does not expose the secure contents).
    public func constantTimeEquals(_ other: [UInt8]) -> Bool {
        guard other.count == count else { return false }
        return other.withUnsafeBufferPointer { o in
            sodium_memcmp(ptr, o.baseAddress, count) == 0
        }
    }

    /// Explicitly zeroes and frees now, ending the value's lifetime.
    /// (deinit does the same; this exists to make custody points loud.)
    public consuming func zeroAndFree() {
        sodium_free(ptr)
        discard self
    }

    deinit {
        // sodium_free zeroes the full region before unmapping.
        sodium_free(ptr)
    }
}

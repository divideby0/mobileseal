import Foundation

/// Process-wide coordination keyed by canonical (symlink-resolved)
/// vault directory path. Two invariants live here because a per-unlock
/// `KeyCustodian` cannot see across sessions (wave-003 blocker,
/// claude-code #1 / codex #1 converging):
///
///   1. WRITER EXCLUSIVITY — at most one `Gallery` per vault directory
///      in this process, across ALL unlock sessions. Claimed by
///      `openGallery()`, released when the owning session locks (or is
///      dropped — the custodian releases in deinit).
///   2. UNLOCK SERIALIZATION — the rate limiter's check→KDF→record
///      sequence runs under a per-vault mutex, so concurrent guesses
///      cannot all pass `checkAllowed` before any failure is recorded
///      (codex #4).
///
/// Multi-PROCESS exclusion remains out of scope (documented; the CLI
/// leg owns an on-disk lock).
final class VaultProcessRegistry: @unchecked Sendable {
    static let shared = VaultProcessRegistry()

    private let lock = NSLock()
    private var writerPaths: Set<String> = []
    private var unlockLocks: [String: NSLock] = [:]

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Claims writer authority for a vault path. False when another
    /// live Gallery in this process already holds it.
    func claimWriter(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writerPaths.insert(path).inserted
    }

    func releaseWriter(path: String) {
        lock.lock()
        writerPaths.remove(path)
        lock.unlock()
    }

    /// Per-vault mutex for the unlock attempt sequence.
    func unlockLock(path: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = unlockLocks[path] { return existing }
        let created = NSLock()
        unlockLocks[path] = created
        return created
    }
}

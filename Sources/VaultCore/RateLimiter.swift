import Foundation

/// Injectable time source so rate-limit tests never sleep.
public struct VaultClock: Sendable {
    public let now: @Sendable () -> TimeInterval  // Unix epoch seconds

    public static let system = VaultClock { Date().timeIntervalSince1970 }
    public init(now: @escaping @Sendable () -> TimeInterval) { self.now = now }
}

/// Local unlock rate-limit/backoff (intake §11, Codex B15). Policy
/// (documented, asserted by green gate 6):
///   - the first `freeAttempts` (5) consecutive failures cost nothing;
///   - failure N (N > 5) starts a cooldown of min(2^(N-5), 300) s from
///     the moment of that failure;
///   - an unlock attempted during cooldown throws `.rateLimited`
///     WITHOUT running the KDF;
///   - a successful unlock resets the counter and removes the sidecar.
/// State persists in `unlock.throttle` beside the gallery — a LOCAL
/// sidecar, explicitly not part of the cross-platform format contract
/// (an attacker with filesystem write access can delete it; this
/// mechanism only throttles the interactive-guessing path).
struct UnlockRateLimiter {
    static let freeAttempts = 5
    static let maxCooldown: TimeInterval = 300

    private static let magic = Array("MSVTHRT0".utf8)

    struct State: Equatable {
        var failureCount: UInt32
        var lastFailureAt: TimeInterval  // Unix epoch seconds
    }

    let url: URL
    let clock: VaultClock

    func load() -> State? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        var r = WireReader([UInt8](data), object: .galleryMeta)
        // Corrupt sidecar → treated as absent (documented; local-only).
        guard (try? r.expectMagic(Self.magic)) != nil,
            let version = try? r.u16(), version == 0,
            let count = try? r.u32(),
            let lastMs = try? r.u64(),
            r.remaining == 0
        else { return nil }
        return State(failureCount: count, lastFailureAt: TimeInterval(lastMs) / 1000)
    }

    private func store(_ state: State) {
        var w = WireWriter()
        w.raw(Self.magic)
        w.u16(0)
        w.u32(state.failureCount)
        w.u64(UInt64(max(0, state.lastFailureAt) * 1000))
        try? FS.write(w.bytes, to: url, fsync: false)
    }

    static func cooldown(afterFailures n: UInt32) -> TimeInterval {
        guard n > UInt32(freeAttempts) else { return 0 }
        let excess = min(n - UInt32(freeAttempts), 32)
        return min(pow(2, Double(excess)), maxCooldown)
    }

    /// Throws `.rateLimited` if a cooldown is still running. Called
    /// BEFORE the KDF.
    func checkAllowed() throws {
        guard let s = load() else { return }
        let cooldown = Self.cooldown(afterFailures: s.failureCount)
        let readyAt = s.lastFailureAt + cooldown
        let now = clock.now()
        if now < readyAt {
            throw VaultError.rateLimited(retryAfterSeconds: readyAt - now)
        }
    }

    func recordFailure() {
        let count = (load()?.failureCount ?? 0) &+ 1
        store(State(failureCount: count, lastFailureAt: clock.now()))
    }

    func recordSuccess() {
        try? FileManager.default.removeItem(at: url)
    }
}

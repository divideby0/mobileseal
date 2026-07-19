import Foundation
import Testing

@testable import VaultCore

/// Green gate 6 (intake §11, Codex B15): local unlock rate limiting.
/// Policy under test (documented in RateLimiter.swift):
///   5 free failures; failure N>5 starts a cooldown of min(2^(N-5),
///   300) s; attempts during cooldown throw `.rateLimited` WITHOUT
///   running the KDF; success resets.
@Suite struct RateLimitTests {
    @Test func backoffFollowsDocumentedPolicy() async throws {
        let fake = FakeClock()
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create(clock: fake.clock)

        let sealed = try vault.open(clock: fake.clock)
        func failOnce() {
            let wrong = try? SecureBytes(nfcNormalizedPassword: "wrong password")
            #expect(throws: VaultError.dekUnwrapFailed) {
                _ = try sealed.unlock(password: wrong!)
            }
        }

        // 5 free failures: no cooldown between them.
        for _ in 0..<5 { failOnce() }

        // 6th failure begins a 2 s cooldown…
        failOnce()
        do {
            let pw = try vault.password()
            _ = try sealed.unlock(password: pw)
            Issue.record("attempt during cooldown must be rate limited")
        } catch let error as VaultError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
            #expect(retryAfter > 0 && retryAfter <= 2)
        }

        // …which expires: after 2 s the (still wrong) attempt reaches
        // the KDF and fails as dekUnwrapFailed, pushing cooldown to 4 s.
        fake.advance(by: 2.1)
        failOnce()
        fake.advance(by: 2.1)  // not enough for the 4 s cooldown
        do {
            let pw = try vault.password()
            _ = try sealed.unlock(password: pw)
            Issue.record("attempt inside 4 s cooldown must be rate limited")
        } catch let error as VaultError {
            guard case .rateLimited = error else {
                Issue.record("expected rateLimited, got \(error)")
                return
            }
        }

        // After the full cooldown, the correct password unlocks and
        // RESETS the limiter.
        fake.advance(by: 4.0)
        let pw = try vault.password()
        let session = try sealed.unlock(password: pw)
        session.lock()
        #expect(FileManager.default.fileExists(atPath: vault.layout.throttleURL.path) == false)

        // Fresh failures start from zero again (5 free).
        for _ in 0..<5 { failOnce() }
        let pw2 = try vault.password()
        let session2 = try sealed.unlock(password: pw2)
        session2.lock()
    }

    @Test func cooldownScheduleIsExactAndCapped() {
        #expect(UnlockRateLimiter.cooldown(afterFailures: 5) == 0)
        #expect(UnlockRateLimiter.cooldown(afterFailures: 6) == 2)
        #expect(UnlockRateLimiter.cooldown(afterFailures: 7) == 4)
        #expect(UnlockRateLimiter.cooldown(afterFailures: 10) == 32)
        #expect(UnlockRateLimiter.cooldown(afterFailures: 14) == 300)  // capped
        #expect(UnlockRateLimiter.cooldown(afterFailures: 1000) == 300)
    }

    @Test func corruptThrottleSidecarIsTreatedAsAbsent() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()
        try Data([0xDE, 0xAD]).write(to: vault.layout.throttleURL)
        let pw = try vault.password()
        let session = try vault.open().unlock(password: pw)
        session.lock()
    }
}

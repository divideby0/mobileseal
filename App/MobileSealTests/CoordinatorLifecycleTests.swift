import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// Coordinator state machine (GOAL WS A.1): create, unlock, unlock
/// failure, lock, relaunch, open-elsewhere. Gate 5's lock assertions
/// (readers fail closed, children cancelled, registry released) live
/// in ScenePhaseLockTests.
@MainActor
@Suite struct CoordinatorLifecycleTests {
    @Test func createReachesUnlockedAndRelaunchNeedsUnlock() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        // Calibration record persisted at creation (WS D.4).
        let record = vault.container.vaultRoot.appendingPathComponent("calibration.json")
        #expect(FileManager.default.fileExists(atPath: record.path))

        // Relaunch: a fresh coordinator over the same container routes
        // to the unlock screen, not setup.
        await vault.coordinator.teardown()
        _ = await TestSupport.waitUntil { vault.sink.phase == .locked }

        let second = VaultCoordinator(
            container: vault.container, calibration: TestSupport.fastCalibration)
        let sink2 = RecordingSink()
        await second.attach(sink: sink2)
        await second.start()
        #expect(await TestSupport.waitUntil { sink2.phase == .locked })

        await second.unlock(password: UnlockedVault.password)
        #expect(await TestSupport.waitUntil { sink2.phase == .unlocked(importing: false) })
        await second.teardown()
    }

    @Test func wrongPasswordSurfacesAmbiguousFailureAndStaysLocked() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        await vault.coordinator.lock()
        _ = await TestSupport.waitUntil { vault.sink.phase == .locked }

        await vault.coordinator.unlock(password: "wrong password")
        #expect(
            await TestSupport.waitUntil {
                vault.sink.unlockFailures.contains(.wrongPasswordOrDamagedKeyring)
            })
        #expect(vault.sink.phase == .locked)
    }

    @Test func repeatedWrongPasswordsHitRateLimit() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        await vault.coordinator.lock()
        _ = await TestSupport.waitUntil { vault.sink.phase == .locked }

        // 5 free failures; failure 6 starts the first 2 s cooldown;
        // attempt 7 is refused without running the KDF (CED-10 gate 6).
        for _ in 0..<7 {
            await vault.coordinator.unlock(password: "wrong password")
            _ = await TestSupport.waitUntil { vault.sink.phase == .locked }
        }
        let sawRateLimit = vault.sink.unlockFailures.contains {
            if case .rateLimited(let seconds) = $0 { return seconds > 0 }
            return false
        }
        #expect(sawRateLimit)
    }

    @Test func secondCoordinatorSeesVaultOpenElsewhere() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        // Same container, second coordinator, same process: the
        // process-wide writer registry must refuse a second Gallery
        // and the failure must read "open elsewhere" (single-scene
        // policy: never a crash).
        let second = VaultCoordinator(
            container: vault.container, calibration: TestSupport.fastCalibration)
        let sink2 = RecordingSink()
        await second.attach(sink: sink2)
        await second.start()
        _ = await TestSupport.waitUntil { sink2.phase == .locked }
        await second.unlock(password: UnlockedVault.password)
        #expect(
            await TestSupport.waitUntil {
                sink2.unlockFailures.contains(.vaultOpenElsewhere)
            })
        #expect(sink2.phase == .locked)

        // After the first coordinator locks, the claim is released and
        // the second unlock succeeds (gate 5's registry-release claim).
        await vault.coordinator.lock()
        _ = await TestSupport.waitUntil { vault.sink.phase == .locked }
        await second.unlock(password: UnlockedVault.password)
        #expect(await TestSupport.waitUntil { sink2.phase == .unlocked(importing: false) })
        await second.teardown()
    }

    @Test func snapshotFeedDeliversFreshReaderPerGeneration() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let readersBefore = vault.sink.readers.count

        let provider = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0000.jpg"))
        await vault.coordinator.startImport(providers: [provider])
        #expect(
            await TestSupport.waitUntil {
                vault.sink.lastSummary != nil
            })
        // Two commits (original + thumbnail) → at least two new
        // generations → at least two fresh readers (Codex B4).
        #expect(vault.sink.readers.count >= readersBefore + 2)
        #expect(vault.sink.items.count == 1)
        #expect(vault.sink.items[0].thumbnailID != nil)
    }
}

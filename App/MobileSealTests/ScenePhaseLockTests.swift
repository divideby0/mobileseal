import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// Gate 5: scene-phase lock behavior. Shield on `.inactive` (redaction
/// ≠ lock); lock + full app-plaintext purge on `.background` under the
/// strict default; readers fail closed after lock; children torn down;
/// process-registry claim released (proved in
/// CoordinatorLifecycleTests.secondCoordinatorSeesVaultOpenElsewhere).
@MainActor
@Suite struct ScenePhaseLockTests {
    /// Builds a store around an unlocked vault with one imported item
    /// and a warmed thumbnail cache.
    private func makeWarmStore() async throws -> (VaultStore, AppContainer) {
        let container = try TestSupport.makeContainer()
        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        // Isolated defaults domain: these tests are app-hosted, and
        // writing lock prefs into .standard would poison later real
        // launches on this simulator (bit the e2e gate).
        let defaults = UserDefaults(suiteName: "scenephase-tests-\(UUID().uuidString)")!
        let store = TestSupport.makeStore(
            coordinator: coordinator, container: container, defaults: defaults)
        await store.bootstrap()
        _ = await TestSupport.waitUntil { store.phase == .needsSetup }
        store.createGallery(password: UnlockedVault.password)
        _ = await TestSupport.waitUntil { store.phase == .unlocked(importing: false) }

        store.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0040.jpg"))
        ])
        _ = await TestSupport.waitUntil { store.lastImportSummary != nil }
        // Wait for the generation whose item carries the thumbnail
        // LINK — the original commits one generation before its
        // thumbnail, and the warm below needs the linked item.
        _ = await TestSupport.waitUntil { store.items.first?.thumbnailID != nil }

        // Warm the decoded-image cache.
        let image = await store.thumbnails.image(for: store.items[0])
        #expect(image != nil)
        #expect(await !store.thumbnails.debugCacheIsEmpty)
        return (store, container)
    }

    @Test func inactiveShieldsButNeverLocks() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }

        store.sceneBecameInactive()
        #expect(store.shielded)
        // Transient inactivity: still unlocked, cache intact.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.phase == .unlocked(importing: false))
        #expect(await !store.thumbnails.debugCacheIsEmpty)

        store.sceneBecameActive()
        #expect(!store.shielded)
        #expect(store.phase == .unlocked(importing: false))
    }

    @Test func backgroundImmediatePolicyLocksAndPurgesEverything() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lockPreferences.backgroundPolicy = .immediate
        let preLockReader = await store.thumbnails.currentReader()
        let item = store.items[0]

        store.sceneEnteredBackground()
        #expect(store.shielded)
        #expect(await TestSupport.waitUntil { store.phase == .locked })

        // App-plaintext purge: decoded cache and in-flight work empty.
        #expect(await store.thumbnails.debugCacheIsEmpty)
        // Items and index gone from the UI state.
        #expect(store.items.isEmpty)
        // Coordinator children torn down (snapshot task cancelled,
        // session consumed, gallery dropped, index purged).
        #expect(await store.coordinator.debugChildrenAreTornDown())

        // A reader that escaped before lock fails CLOSED.
        if let escaped = preLockReader {
            #expect(throws: VaultError.vaultLocked) {
                try escaped.readRange(fileID: item.id, offset: 0, length: 4) { _ in () }
            }
        } else {
            Issue.record("expected a live reader before lock")
        }

        // Pipeline requests after purge yield nothing (reader is nil).
        let after = await store.thumbnails.image(for: item)
        #expect(after == nil)
    }

    @Test func gracePolicyLocksOnlyAfterWindowOnReturn() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lockPreferences.backgroundPolicy = .grace
        store.lockPreferences.gracePeriod = 0.1

        // Short absence: no lock.
        store.sceneEnteredBackground()
        #expect(store.phase == .unlocked(importing: false))
        store.sceneBecameActive()
        #expect(store.phase == .unlocked(importing: false))
        #expect(!store.shielded)

        // Absence past the window: locks on return, and the shield
        // STAYS UP until the phase actually reaches .locked (wave-001
        // cc #5 / codex #1 / coderabbit: the old path flashed the
        // unlocked grid during the async lock).
        store.sceneEnteredBackground()
        try? await Task.sleep(for: .milliseconds(250))
        store.sceneBecameActive()
        #expect(store.shielded, "shield must not drop while the grace lock is pending")
        #expect(await TestSupport.waitUntil { store.phase == .locked })
        #expect(await TestSupport.waitUntil { !store.shielded })
        #expect(await store.thumbnails.debugCacheIsEmpty)
    }

    @Test func offPolicyNeverAutoLocks() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lockPreferences.backgroundPolicy = .off
        store.sceneEnteredBackground()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.phase == .unlocked(importing: false))
        // The shield still raises — redaction is unconditional.
        #expect(store.shielded)
    }

    @Test func idleBackstopLocksAfterTimeout() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lockPreferences.idleTimeout = 0.2
        store.startIdleWatch(pollInterval: .milliseconds(50))
        #expect(await TestSupport.waitUntil(timeout: .seconds(5)) { store.phase == .locked })
        #expect(await store.thumbnails.debugCacheIsEmpty)
    }

    /// Wave-001 regression (cc #1 / coderabbit): a decode in flight
    /// across purge() must never repopulate the emptied cache when it
    /// resumes — the actor's await is a reentrancy point.
    @Test func purgeDuringInflightDecodesLeavesCacheEmpty() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        let items = store.items
        // Race purge against a burst of concurrent decodes, many times.
        for _ in 0..<20 {
            await store.thumbnails.purge()
            let reader = await store.coordinator.debugGallery()?.makeReader()
            await store.thumbnails.setReader(reader)
            let requests = (0..<8).map { _ in
                Task { await store.thumbnails.image(for: items[0]) }
            }
            await store.thumbnails.purge()
            for request in requests { _ = await request.value }
            #expect(await store.thumbnails.debugCacheIsEmpty)
        }
    }

    @Test func explicitLockControlWorks() async throws {
        let (store, container) = try await makeWarmStore()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lock()
        #expect(await TestSupport.waitUntil { store.phase == .locked })
        #expect(await store.thumbnails.debugCacheIsEmpty)
        #expect(await store.coordinator.debugChildrenAreTornDown())
    }
}

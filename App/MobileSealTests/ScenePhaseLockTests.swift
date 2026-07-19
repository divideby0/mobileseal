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
            container: container, calibration: TestSupport.fastCalibration)
        let store = VaultStore(coordinator: coordinator)
        await store.bootstrap()
        _ = await TestSupport.waitUntil { store.phase == .needsSetup }
        store.createGallery(password: UnlockedVault.password)
        _ = await TestSupport.waitUntil { store.phase == .unlocked(importing: false) }

        store.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0040.jpg"))
        ])
        _ = await TestSupport.waitUntil { store.lastImportSummary != nil }
        _ = await TestSupport.waitUntil { !store.items.isEmpty }

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

        // Short absence: no lock.
        store.sceneEnteredBackground()
        #expect(store.phase == .unlocked(importing: false))
        store.sceneBecameActive()
        #expect(store.phase == .unlocked(importing: false))
        #expect(!store.shielded)
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

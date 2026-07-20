import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// The two-commit recovery rule (Codex B2, GOAL WS B.3): original and
/// thumbnail are independent commits — a missing thumbnail regenerates
/// on open, an orphaned thumbnail is ignored and reported.
@MainActor
@Suite struct ThumbnailRecoveryTests {
    /// Imports an original WITHOUT its thumbnail commit (simulating a
    /// crash between the two), then verifies the STORE's on-open
    /// wiring heals it with no manual coordinator call — wave-001
    /// cc #2 / codex #5 caught the previous test asserting a wiring
    /// that did not exist.
    @Test func missingThumbnailRegeneratesThroughStoreWiring() async throws {
        let container = try TestSupport.makeContainer()
        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration)
        let defaults = UserDefaults(suiteName: "recovery-tests-\(UUID().uuidString)")!
        let store = VaultStore(
            coordinator: coordinator, container: container, defaults: defaults)
        defer {
            Task {
                await coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        await store.bootstrap()
        _ = await TestSupport.waitUntil { store.phase == .needsSetup }
        store.createGallery(password: UnlockedVault.password)
        _ = await TestSupport.waitUntil { store.phase == .unlocked(importing: false) }

        // Crash window: only the original commits.
        let stillURL = try TestSupport.fixtureURL("fixture-0032.jpg")
        var meta = MediaMetadata(kind: .original, importedAt: Date())
        meta.filename = "fixture-0032.jpg"
        meta.contentHash = try ImportEngine.sha256Hex(of: stillURL)
        let gallery = try #require(await coordinator.debugGallery())
        _ = try await gallery.importFile(at: stillURL, metadata: meta.encoded())

        // The snapshot feed reports the missing thumbnail and the
        // store schedules regeneration on its own.
        #expect(
            await TestSupport.waitUntil {
                store.items.first?.thumbnailID != nil
            }, "on-open recovery never healed the missing thumbnail")
        #expect(store.indexReport.missingThumbnails == 0)
    }

    @Test func orphanThumbnailIsIgnoredAndReported() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        // A thumbnail whose parent never existed (parent entry lost).
        let gallery = try #require(await vault.coordinator.debugGallery())
        var thumbMeta = MediaMetadata(kind: .thumbnail, importedAt: Date())
        thumbMeta.parent = FileID().description
        _ = try await gallery.importBytes(
            [UInt8](try Data(contentsOf: TestSupport.fixtureURL("fixture-0034.jpg"))),
            metadata: thumbMeta.encoded())

        _ = await TestSupport.waitUntil { (vault.sink.reports.last?.orphanThumbnails ?? 0) == 1 }
        // Ignored for display: no grid item appears.
        #expect(vault.sink.items.isEmpty)
        #expect(vault.sink.reports.last?.orphanThumbnails == 1)
    }

    /// An unparseable metadata blob is surfaced, never a crash and
    /// never silently dropped.
    @Test func undecodableMetadataIsReported() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let gallery = try #require(await vault.coordinator.debugGallery())
        _ = try await gallery.importBytes(
            Array("some payload".utf8), metadata: Array("not json".utf8))
        _ = await TestSupport.waitUntil {
            (vault.sink.reports.last?.undecodableEntries ?? 0) == 1
        }
        #expect(vault.sink.reports.last?.undecodableEntries == 1)
    }
}

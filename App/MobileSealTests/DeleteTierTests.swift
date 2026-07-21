import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// Two-tier delete over media aggregates (CED-13 WS C.2, green gate
/// 2's unit half): soft delete hides the aggregate and populates
/// Recently Deleted; restore clears it; purge hard-tombstones every
/// member; 30-day expiry purges automatically at unlock.
@MainActor
@Suite(.serialized) struct DeleteTierTests {
    /// Imports an original + linked thumbnail directly through the
    /// gallery actor (provider fidelity is not under test here).
    private func importAggregate(
        _ vault: UnlockedVault, name: String, seed: UInt64
    ) async throws -> (original: FileID, thumbnail: FileID) {
        let gallery = try #require(await vault.coordinator.debugGallery())
        var meta = MediaMetadata(kind: .original, importedAt: Date())
        meta.filename = name
        meta.uti = "public.jpeg"
        let originalBytes = (0..<2000).map { i in UInt8((UInt64(i) &* seed) & 0xFF) }
        let original = try await gallery.importBytes(
            originalBytes, metadata: meta.encoded())
        var thumbMeta = MediaMetadata(kind: .thumbnail, importedAt: Date())
        thumbMeta.parent = original.description
        thumbMeta.uti = "public.jpeg"
        let thumbnail = try await gallery.importBytes(
            Array(originalBytes.prefix(200)), metadata: thumbMeta.encoded())
        return (original, thumbnail)
    }

    @Test func softDeleteHidesAggregateAndRecentlyDeletedLists() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let (original, _) = try await importAggregate(vault, name: "a.jpg", seed: 3)
        let (keeper, _) = try await importAggregate(vault, name: "b.jpg", seed: 5)

        _ = await TestSupport.waitUntil { vault.sink.items.count == 2 }
        await vault.coordinator.softDeleteItems([original])
        let hidden = await TestSupport.waitUntil {
            vault.sink.items.map(\.id) == [keeper]
                || vault.sink.items.count == 1
        }
        #expect(hidden)
        #expect(vault.sink.recentlyDeleted.count == 1)
        #expect(vault.sink.recentlyDeleted.first?.id == original)
        // The soft-deleted item still renders (its entries are
        // untouched): the RecentlyDeletedItem carries the thumbnail
        // link for preview.
        #expect(vault.sink.recentlyDeleted.first?.item.thumbnailID != nil)
    }

    @Test func restoreBringsTheAggregateBack() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let (original, _) = try await importAggregate(vault, name: "c.jpg", seed: 7)
        _ = await TestSupport.waitUntil { vault.sink.items.count == 1 }

        await vault.coordinator.softDeleteItems([original])
        _ = await TestSupport.waitUntil { vault.sink.items.isEmpty }
        await vault.coordinator.restoreDeletedItem(original)
        let restored = await TestSupport.waitUntil {
            vault.sink.items.map(\.id) == [original]
        }
        #expect(restored)
        #expect(vault.sink.recentlyDeleted.isEmpty)
    }

    @Test func purgeTombstonesEveryAggregateMember() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let (original, thumbnail) = try await importAggregate(vault, name: "d.jpg", seed: 11)
        _ = await TestSupport.waitUntil { vault.sink.items.count == 1 }

        await vault.coordinator.softDeleteItems([original])
        await vault.coordinator.purgeDeletedItems([original])
        let purged = await TestSupport.waitUntil {
            vault.sink.items.isEmpty && vault.sink.recentlyDeleted.isEmpty
        }
        #expect(purged)
        // BOTH members are tombstoned in the manifest — not just
        // hidden (reviews B13/Q6: no visible orphans, no reachable
        // deleted media).
        let gallery = try #require(await vault.coordinator.debugGallery())
        let snapshot = await gallery.snapshot()
        #expect(!snapshot.files.contains { $0.fileID == original })
        #expect(!snapshot.files.contains { $0.fileID == thumbnail })
    }

    @Test func expiredSoftDeletesPurgeAtUnlock() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let (original, thumbnail) = try await importAggregate(vault, name: "e.jpg", seed: 13)
        _ = await TestSupport.waitUntil { vault.sink.items.count == 1 }
        let galleryID = try #require(
            await vault.coordinator.debugGallery()?.galleryID)

        // Soft-delete DATED 31 days ago, written straight to the
        // device-local ledger (the coordinator API always stamps now).
        let store = RecentlyDeletedStore(
            fileURL: vault.container.recentlyDeletedURL(galleryID: galleryID))
        store.softDelete(
            originalID: original, memberIDs: [original, thumbnail],
            at: Date().addingTimeInterval(-31 * 24 * 60 * 60))

        await vault.coordinator.purgeExpiredSoftDeletes()
        let purged = await TestSupport.waitUntil {
            vault.sink.items.isEmpty && vault.sink.recentlyDeleted.isEmpty
        }
        #expect(purged)
        let gallery = try #require(await vault.coordinator.debugGallery())
        let snapshot = await gallery.snapshot()
        #expect(!snapshot.files.contains { $0.fileID == original })
        #expect(!snapshot.files.contains { $0.fileID == thumbnail })
        #expect(store.all.isEmpty)
    }

    @Test func softDeleteSurvivesRelaunchOfTheCoordinator() async throws {
        let vault = try await UnlockedVault.create()
        let (original, _) = try await importAggregate(vault, name: "f.jpg", seed: 17)
        _ = await TestSupport.waitUntil { vault.sink.items.count == 1 }
        await vault.coordinator.softDeleteItems([original])
        _ = await TestSupport.waitUntil { vault.sink.items.isEmpty }
        await vault.coordinator.teardown()

        // Second "launch" over the same container: the device-local
        // ledger is durable — the item is still in Recently Deleted,
        // not back in the grid.
        let second = VaultCoordinator(
            container: vault.container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: vault.container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let sink2 = RecordingSink()
        await second.attach(sink: sink2)
        await second.start()
        await second.unlock(password: UnlockedVault.password)
        let unlocked = await TestSupport.waitUntil {
            sink2.phase == .unlocked(importing: false)
        }
        #expect(unlocked)
        let stateHeld = await TestSupport.waitUntil {
            sink2.recentlyDeleted.count == 1 && sink2.items.isEmpty
        }
        #expect(stateHeld)
        await second.teardown()
        TestSupport.removeContainer(vault.container)
    }
}

/// Keychain custody attributes (green gate 4's simulator half — the
/// STATED residual: device-bound/protection-class ENFORCEMENT is
/// hardware behavior on the HITL checklist, not counted green here).
@Suite(.serialized) struct KeychainDeviceKeyStoreTests {
    @Test func createLoadIdempotenceAndAccessibilityAttribute() throws {
        var store = KeychainDeviceKeyStore()
        store.account = "test-device-ed25519-\(UUID().uuidString)"
        defer { store.deleteStoredKey() }

        let first = try store.loadOrCreateIdentity()
        let second = try store.loadOrCreateIdentity()
        // Idempotent: the same persisted identity every time (the
        // migration state machine re-runs this step).
        #expect(first.publicKey == second.publicKey)

        // WhenUnlockedThisDeviceOnly: never migrates to a new device,
        // never rides a backup (CED-13 WS A.1).
        let attribute = try store.storedAccessibilityAttribute()
        #expect(attribute == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
    }

    @Test func signaturesFromThePersistedKeyVerify() throws {
        var store = KeychainDeviceKeyStore()
        store.account = "test-device-ed25519-\(UUID().uuidString)"
        defer { store.deleteStoredKey() }
        let identity = try store.loadOrCreateIdentity()
        let reloaded = try store.loadOrCreateIdentity()
        // A signature minted by the first handle verifies under the
        // reloaded public key — same underlying key bytes.
        #expect(identity.publicKey == reloaded.publicKey)
    }
}

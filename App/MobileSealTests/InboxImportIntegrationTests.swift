import Foundation
import Testing
import UniformTypeIdentifiers
import VaultCore

@testable import MobileSeal

/// CED-15 gate 3 (integration half): committed inbox items → main-app
/// prompt → gallery-bound claim through the switch authority → the
/// REAL import pipeline → inbox cleared; decline keeps; per-item
/// discard; integrity mismatch rejected before import; interruption
/// leaves no stranded claims.
@MainActor
@Suite struct InboxImportIntegrationTests {

    struct Fixture {
        let store: VaultStore
        let container: AppContainer
        let inbox: InboxStore

        func destroy() async {
            await store.coordinator.teardown()
            TestSupport.removeContainer(container)
            try? FileManager.default.removeItem(
                at: inbox.inboxDir.deletingLastPathComponent())
        }
    }

    private func makeFixture() async throws -> Fixture {
        let container = try TestSupport.makeContainer()
        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let inboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inbox-integration-\(UUID().uuidString)/Inbox", isDirectory: true)
        let inbox = try InboxStore(inboxDir: inboxDir)
        let defaults = UserDefaults(suiteName: "inbox-tests-\(UUID().uuidString)")!
        let store = TestSupport.makeStore(
            coordinator: coordinator, container: container, defaults: defaults, inbox: inbox)
        await store.bootstrap()
        _ = await TestSupport.waitUntil { store.phase == .needsSetup }
        store.createGallery(password: UnlockedVault.password)
        _ = await TestSupport.waitUntil { store.phase == .unlocked(importing: false) }
        return Fixture(store: store, container: container, inbox: inbox)
    }

    /// Stages fixtures into the inbox through the real writer.
    private func stage(_ fixtures: [String], into inbox: InboxStore) async throws {
        var attachments: [any InboxAttachment] = []
        for fixture in fixtures {
            attachments.append(
                FakeAttachment(
                    registeredTypeIdentifiers: [UTType.jpeg.identifier],
                    suggestedName: fixture,
                    representations: [
                        UTType.jpeg.identifier: try TestSupport.fixtureURL(fixture)
                    ]))
        }
        let outcomes = await InboxWriter(store: inbox).stage(attachments: attachments)
        for outcome in outcomes {
            guard case .staged = outcome.status else {
                throw TestError("staging fixture failed: \(outcome.status)")
            }
        }
    }

    @Test func acceptImportsThroughRealPipelineAndClearsInbox() async throws {
        let fx = try await makeFixture()
        defer { Task { await fx.destroy() } }
        try await stage(["fixture-0000.jpg", "fixture-0002.jpg"], into: fx.inbox)

        // Discovery (activation trigger) → exactly-once prompt.
        fx.store.discoverInbox()
        let prompt = try #require(fx.store.pendingInboxPrompt)
        #expect(prompt.items.count == 2)

        fx.store.acceptInboxImport()
        #expect(await TestSupport.waitUntil { fx.store.lastImportSummary != nil })
        #expect(fx.store.lastImportSummary?.importedCount == 2)
        _ = await TestSupport.waitUntil { fx.store.items.count == 2 }

        // Inbox cleared: no committed, no claims, no payloads.
        #expect(await TestSupport.waitUntil { fx.inbox.scan().committed.isEmpty })
        #expect(fx.inbox.scan().claimed.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: fx.inbox.inboxDir, includingPropertiesForKeys: nil)) ?? []
        #expect(files.isEmpty, "inbox not fully cleared: \(files.map(\.lastPathComponent))")

        // No re-prompt for an emptied inbox.
        fx.store.discoverInbox()
        #expect(fx.store.pendingInboxPrompt == nil)
    }

    @Test func declineKeepsCommittedItemsAndOnlyNewArrivalsReprompt() async throws {
        let fx = try await makeFixture()
        defer { Task { await fx.destroy() } }
        try await stage(["fixture-0004.jpg"], into: fx.inbox)

        fx.store.discoverInbox()
        #expect(fx.store.pendingInboxPrompt != nil)
        fx.store.declineInboxPrompt()

        // Same batch: no second prompt (Codex A4 exactly-once).
        fx.store.discoverInbox()
        #expect(fx.store.pendingInboxPrompt == nil)
        // The declined item persists, visible to Settings.
        #expect(fx.inbox.scan().committed.count == 1)
        #expect(fx.store.stagedInboxItems.count == 1)

        // A NEW arrival re-prompts, with the declined item riding
        // along in the batch.
        try await stage(["fixture-0006.jpg"], into: fx.inbox)
        fx.store.discoverInbox()
        let prompt = try #require(fx.store.pendingInboxPrompt)
        #expect(prompt.items.count == 2)
    }

    @Test func perItemDiscardRemovesStagedItem() async throws {
        let fx = try await makeFixture()
        defer { Task { await fx.destroy() } }
        try await stage(["fixture-0008.jpg", "fixture-0010.jpg"], into: fx.inbox)

        fx.store.discoverInbox()
        fx.store.declineInboxPrompt()
        let victim = try #require(fx.store.stagedInboxItems.first)
        fx.store.discardInboxItem(victim.id)
        #expect(fx.store.stagedInboxItems.count == 1)
        #expect(fx.inbox.scan().committed.count == 1)
        #expect(fx.inbox.scan().committed.first?.id != victim.id)
    }

    /// Truncated/substituted payloads are rejected BEFORE import
    /// (manifest hash/length validation) and discarded — never
    /// imported, never re-offered forever.
    @Test func integrityMismatchRejectsBeforeImportAndDiscards() async throws {
        let fx = try await makeFixture()
        defer { Task { await fx.destroy() } }
        try await stage(["fixture-0012.jpg"], into: fx.inbox)

        // Corrupt the committed payload AFTER the manifest was
        // written (a substitution attack / torn write).
        let item = try #require(fx.inbox.scan().committed.first)
        let payload = fx.inbox.payloadURL(for: item.manifest.parts[0])
        try Data("tampered".utf8).write(to: payload)

        fx.store.discoverInbox()
        #expect(fx.store.pendingInboxPrompt != nil)
        fx.store.acceptInboxImport()
        #expect(await TestSupport.waitUntil { fx.store.lastImportSummary != nil })
        let outcome = try #require(fx.store.lastImportSummary?.outcomes.first)
        guard case .failed(.integrityMismatch) = outcome.status else {
            Issue.record("expected integrityMismatch, got \(outcome.status)")
            return
        }
        // Nothing imported; the corrupt item was discarded, not
        // released (it can never import).
        #expect(fx.store.items.isEmpty)
        #expect(await TestSupport.waitUntil { fx.inbox.scan().committed.isEmpty })
        #expect(fx.inbox.scan().claimed.isEmpty)
    }

    /// The claim binds to the LIVE gallery through the switch
    /// authority: a stale gallery ID (switched/locked underneath)
    /// refuses — nothing claimed, nothing imported.
    @Test func claimRefusesWhenGalleryNoLongerLive() async throws {
        let fx = try await makeFixture()
        defer { Task { await fx.destroy() } }
        let accepted = await fx.store.switchboard.claimBoundToLiveGallery(UUID()) {
            Issue.record("body must not run for a non-live gallery")
            return true
        }
        #expect(!accepted)

        // And with the vault locked, even the REAL gallery id refuses.
        let galleryID = try #require(fx.store.selectedGalleryID)
        fx.store.lock()
        _ = await TestSupport.waitUntil { fx.store.phase == .locked }
        let afterLock = await fx.store.switchboard.claimBoundToLiveGallery(galleryID) {
            Issue.record("body must not run after lock")
            return true
        }
        #expect(!afterLock)
    }

    /// Lock racing an accepted inbox import: whichever side wins, the
    /// terminal state holds the custody invariant — no stranded
    /// claims; items either imported (consumed) or committed again.
    @Test func lockDuringInboxImportLeavesNoStrandedClaims() async throws {
        let fx = try await makeFixture()
        defer { Task { await fx.destroy() } }
        try await stage(
            ["fixture-0014.jpg", "fixture-0016.jpg", "fixture-0018.jpg"], into: fx.inbox)

        fx.store.discoverInbox()
        #expect(fx.store.pendingInboxPrompt != nil)
        fx.store.acceptInboxImport()
        fx.store.lock()
        _ = await TestSupport.waitUntil { fx.store.phase == .locked }

        // No claim survives the teardown/summary settlement.
        #expect(await TestSupport.waitUntil { fx.inbox.scan().claimed.isEmpty })
        // Conservation: every staged item is either in the vault
        // (imported before the lock won) or still committed in the
        // inbox — never lost.
        let committed = fx.inbox.scan().committed.count
        fx.store.unlock(password: UnlockedVault.password)
        _ = await TestSupport.waitUntil { fx.store.phase == .unlocked(importing: false) }
        _ = await TestSupport.waitUntil { fx.store.items.count + committed >= 3 }
        #expect(fx.store.items.count + committed >= 3)
    }

    /// Bootstrap releases orphaned claims (app died mid-import).
    @Test func bootstrapReleasesOrphanClaims() async throws {
        let inboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inbox-orphan-\(UUID().uuidString)/Inbox", isDirectory: true)
        let inbox = try InboxStore(inboxDir: inboxDir)
        defer {
            try? FileManager.default.removeItem(at: inboxDir.deletingLastPathComponent())
        }
        try await stage(["fixture-0020.jpg"], into: inbox)
        let item = try #require(inbox.scan().committed.first)
        try inbox.claim(itemIDs: [item.id], galleryID: UUID())
        #expect(inbox.scan().claimed.count == 1)

        // A fresh app process bootstraps → sweep releases the claim.
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let defaults = UserDefaults(suiteName: "inbox-orphan-\(UUID().uuidString)")!
        let store = TestSupport.makeStore(
            coordinator: coordinator, container: container, defaults: defaults, inbox: inbox)
        await store.bootstrap()
        _ = await TestSupport.waitUntil { store.phase == .needsSetup }
        #expect(inbox.scan().claimed.isEmpty)
        #expect(inbox.scan().committed.count == 1)
        await store.coordinator.teardown()
    }
}

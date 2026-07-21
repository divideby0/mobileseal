import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// Gate 4: the CED-10 custody canary extended to the app container.
/// Claim: no plaintext image bytes exist anywhere under the app
/// container outside `staging/` during its documented lifecycle
/// (created → imported → removed), and staging is empty after import
/// completion, after cancellation, and after a simulated-crash
/// relaunch. Backup policy: nothing under the vault root is excluded
/// from backup (grill Q7). Audited path set: the app container base
/// (vault root + galleries + staging). Swap, core dumps, and other
/// processes' caches remain outside the claim, as in CED-10.
@MainActor
@Suite struct AppCustodyCanaryTests {
    /// A canary image: a real decodable JPEG with a distinctive byte
    /// trailer (decoders ignore post-EOI bytes; the vault seals the
    /// whole thing byte-exact).
    private static let canary = Array("MOBILESEAL-CANARY-7f3a9c2e-plaintext-marker".utf8)

    private func makeCanaryImage() throws -> URL {
        let base = try Data(contentsOf: TestSupport.fixtureURL("fixture-0036.jpg"))
        var bytes = [UInt8](base)
        bytes.append(contentsOf: Self.canary)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("canary-\(UUID().uuidString).jpg")
        try Data(bytes).write(to: url)
        return url
    }

    private func containerBase(_ container: AppContainer) -> URL {
        container.vaultRoot.deletingLastPathComponent()
    }

    @Test func afterImportCompletionNoPlaintextAnywhere() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let canaryURL = try makeCanaryImage()
        defer { try? FileManager.default.removeItem(at: canaryURL) }

        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: canaryURL)
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        #expect(vault.sink.lastSummary?.importedCount == 1)

        // The canary went THROUGH staging and INTO the vault — and
        // must now exist nowhere in the container in plaintext.
        let hits = TestSupport.filesContaining(
            Self.canary, under: containerBase(vault.container))
        #expect(hits.isEmpty, "plaintext canary found at: \(hits)")

        // Staging empty after completion.
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: vault.container.stagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(staged.isEmpty)

        // And the round trip still yields the exact canary bytes
        // through the session plane (the vault really holds them).
        let item = try #require(vault.sink.items.first)
        let reader = try #require(vault.sink.currentReader)
        let restored = try VaultCoordinator.decryptWhole(
            fileID: item.id, length: item.byteLength, reader: reader)
        #expect(restored.range(of: Data(Self.canary)) != nil)
    }

    @Test func afterCancellationStagingIsEmptyAndClean() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let canaryURL = try makeCanaryImage()
        defer { try? FileManager.default.removeItem(at: canaryURL) }

        var slow = FixtureMediaProvider(fixtureURL: canaryURL)
        slow.behavior = .delay(1.5)
        await vault.coordinator.startImport(providers: [slow, slow])
        try? await Task.sleep(for: .milliseconds(150))
        await vault.coordinator.lock()
        #expect(await TestSupport.waitUntil { vault.sink.phase == .locked })
        _ = await TestSupport.waitUntil { vault.sink.lastSummary != nil }

        let staged = (try? FileManager.default.contentsOfDirectory(
            at: vault.container.stagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(staged.isEmpty)
        let hits = TestSupport.filesContaining(
            Self.canary, under: containerBase(vault.container))
        #expect(hits.isEmpty, "plaintext canary found at: \(hits)")
    }

    @Test func simulatedCrashRelaunchWipesStrandedStaging() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }

        // A crash mid-import strands plaintext in staging: plant it
        // directly (no import running), then "relaunch".
        let batchDir = try container.makeBatchStagingDirectory()
        let stranded = batchDir.appendingPathComponent("stranded.jpg")
        try Data(Self.canary).write(to: stranded)
        #expect(FileManager.default.fileExists(atPath: stranded.path))

        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let sink = RecordingSink()
        await coordinator.attach(sink: sink)
        await coordinator.start()
        _ = await TestSupport.waitUntil { sink.phase != nil && sink.phase != .starting }

        let staged = (try? FileManager.default.contentsOfDirectory(
            at: container.stagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(staged.isEmpty)
        let hits = TestSupport.filesContaining(
            Self.canary, under: containerBase(container))
        #expect(hits.isEmpty, "stranded staging plaintext survived relaunch: \(hits)")
    }

    @Test func vaultRootParticipatesInBackup() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0038.jpg"))
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })

        // Nothing under the vault root may carry the backup-exclusion
        // flag (grill Q7: ciphertext participates in backup).
        var excluded: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: vault.container.vaultRoot,
            includingPropertiesForKeys: [.isExcludedFromBackupKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            if values?.isExcludedFromBackup == true {
                excluded.append(url.path)
            }
        }
        #expect(excluded.isEmpty, "backup-excluded vault files: \(excluded)")

        // Staging, by contrast, IS excluded.
        let stagingValues = try? vault.container.stagingDir.resourceValues(
            forKeys: [.isExcludedFromBackupKey])
        #expect(stagingValues?.isExcludedFromBackup == true)
    }

    /// The Data Protection attribute is REQUESTED on the container
    /// dirs. The simulator does not enforce protection classes
    /// (documented device-only gap, Codex A7); this asserts our side
    /// of the contract — the attribute we set — wherever the
    /// filesystem reports one.
    @Test func protectionClassRequestedOnContainerDirs() throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        #if os(iOS)
            for dir in [container.vaultRoot, container.stagingDir, container.exportStagingDir] {
                let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
                if let protection = attrs[.protectionKey] as? FileProtectionType {
                    #expect(protection == .completeUnlessOpen)
                }
            }
        #endif
    }

    // MARK: - CED-15 gate 4: export staging + share inbox

    /// Export custody (CED-15 WS A): staged decrypted bytes live under
    /// StagingExport/ ONLY between "staged" and the share sheet's
    /// completion sweep — the ONE documented plaintext window of the
    /// deliberate custody exit. THE CLAIM'S BOUNDARY (Codex A5): it
    /// ends at the provider handoff — bytes an activity chosen in the
    /// share sheet copies for itself belong to the OS from that
    /// moment; completion-handler cleanup cannot and does not claim to
    /// recall them.
    @Test func exportCanaryGoneAfterCompletionSweepAndAfterLock() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let canaryURL = try makeCanaryImage()
        defer { try? FileManager.default.removeItem(at: canaryURL) }

        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: canaryURL)
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        _ = await TestSupport.waitUntil { !vault.sink.items.isEmpty }

        // Stage for share: the canary is NOW under StagingExport/ —
        // the documented window.
        let result = await vault.coordinator.stageExport(items: vault.sink.items)
        guard case .success(let batch) = result else {
            Issue.record("stageExport failed: \(result)")
            return
        }
        let windowHits = TestSupport.filesContaining(
            Self.canary, under: vault.container.exportStagingDir)
        #expect(!windowHits.isEmpty, "the staged export should hold the canary")

        // Completion sweep → gone from the WHOLE container.
        await vault.coordinator.finishExport(batchID: batch.id)
        var hits = TestSupport.filesContaining(
            Self.canary, under: containerBase(vault.container))
        #expect(hits.isEmpty, "plaintext canary found after completion sweep: \(hits)")

        // Stage again, then LOCK mid-share: the export participant
        // sweeps before the custodian drain.
        guard case .success = await vault.coordinator.stageExport(items: vault.sink.items)
        else {
            Issue.record("second stageExport failed")
            return
        }
        await vault.coordinator.lock()
        hits = TestSupport.filesContaining(
            Self.canary, under: containerBase(vault.container))
        #expect(hits.isEmpty, "plaintext canary found after mid-share lock: \(hits)")
    }

    /// Inbox custody (CED-15 WS B, Codex B7): app-group containers
    /// inherit neither Data Protection nor backup exclusion, so BOTH
    /// are asserted per file the writer creates. Simulator asserts the
    /// attributes we set; device ENFORCEMENT is the stated residual.
    @Test func inboxFilesCarryProtectionAndBackupExclusion() async throws {
        let inboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inbox-canary-\(UUID().uuidString)/Inbox", isDirectory: true)
        let inbox = try InboxStore(inboxDir: inboxDir)
        defer {
            try? FileManager.default.removeItem(at: inboxDir.deletingLastPathComponent())
        }
        let canaryURL = try makeCanaryImage()
        defer { try? FileManager.default.removeItem(at: canaryURL) }

        let attachment = FakeAttachment(
            registeredTypeIdentifiers: ["public.jpeg"],
            suggestedName: "canary.jpg",
            representations: ["public.jpeg": canaryURL])
        let outcomes = await InboxWriter(store: inbox).stage(attachments: [attachment])
        guard case .staged(let manifest) = outcomes[0].status else {
            Issue.record("staging failed: \(outcomes[0].status)")
            return
        }

        // Every file of the item — payload AND manifest — carries the
        // exclusion flag; protection is asserted where reported.
        var audited = [inbox.payloadURL(for: manifest.parts[0])]
        audited.append(
            inbox.inboxDir.appendingPathComponent(
                InboxManifest.manifestName(itemID: manifest.itemID)))
        for url in audited {
            let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(
                values?.isExcludedFromBackup == true,
                "inbox file not backup-excluded: \(url.lastPathComponent)")
            #if os(iOS)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if let protection = attrs[.protectionKey] as? FileProtectionType {
                    #expect(protection == .completeUnlessOpen)
                }
            #endif
        }

        // The staged payload is plaintext by design (the inbox is the
        // documented pre-import window, like Staging/) — but after a
        // full import-and-clear cycle nothing may remain.
        inbox.remove(itemID: manifest.itemID)
        let hits = TestSupport.filesContaining(Self.canary, under: inboxDir)
        #expect(hits.isEmpty, "inbox retained plaintext after removal: \(hits)")
    }
}

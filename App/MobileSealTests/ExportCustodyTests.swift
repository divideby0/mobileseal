import Foundation
import Testing
import UIKit
import VaultCore

@testable import MobileSeal

/// CED-15 gate 2: export e2e over the provider-consumption seam. The
/// exported items' load handlers are invoked directly — the same
/// `UIActivityItemSource` calls Photos/Files/AirDrop make — asserting
/// correct bytes, filename, and UTI per item type; completion,
/// cancellation, and mid-share lock each cancel + sweep StagingExport/
/// (including the simulated-crash relaunch), and the grace/off
/// background override fires. Custody boundary (Codex A5): these
/// claims end at the provider handoff — bytes a chosen activity copies
/// are the OS's.
@MainActor
@Suite struct ExportCustodyTests {

    /// Drives the UIActivityItemSource seam exactly as an activity
    /// would (a dummy controller satisfies the API's parameter).
    private func consume(_ file: ExportFileItem) -> (bytes: Data?, uti: String, subject: String) {
        let item = ExportActivityItem(file: file)
        let dummy = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let loaded = item.activityViewController(dummy, itemForActivityType: nil)
        let url = loaded as? URL
        return (
            bytes: url.flatMap { try? Data(contentsOf: $0) },
            uti: item.activityViewController(dummy, dataTypeIdentifierForActivityType: nil),
            subject: item.activityViewController(dummy, subjectForActivityType: nil)
        )
    }

    @Test func stillVideoAndLivePhotoExportWithExactBytesNamesAndUTIs() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        let still = try TestSupport.fixtureURL("fixture-0000.jpg")
        let video = try TestSupport.fixtureURL("video-faststart.mp4")
        let pairedStill = try TestSupport.fixtureURL("fixture-0002.jpg")
        let pairedVideo = try TestSupport.fixtureURL("video-paired.mov")

        var live = FixtureMediaProvider(fixtureURL: pairedStill)
        live.pairedVideoURL = pairedVideo
        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: still),
            FixtureMediaProvider(fixtureURL: video),
            live,
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        #expect(vault.sink.lastSummary?.importedCount == 3)
        // Wait for the generation that carries the Live-Photo video
        // LINK — the paired entry commits after its original.
        _ = await TestSupport.waitUntil {
            vault.sink.items.count == 3
                && vault.sink.items.contains { $0.livePhotoVideoID != nil }
        }
        let items = vault.sink.items
        let livePhotoItem = try #require(items.first { $0.livePhotoVideoID != nil })

        let result = await vault.coordinator.stageExport(items: items)
        guard case .success(let batch) = result else {
            Issue.record("stageExport failed: \(result)")
            return
        }
        // 3 selected entries → 4 file items: the Live Photo exports as
        // TWO separate files (Codex B5 — re-pairing needs PhotoKit
        // write auth we do not hold).
        #expect(batch.files.count == 4)

        // Per item type: bytes exact, filename preserved, UTI correct
        // — via the consumption seam, as an activity would load them.
        let byName = Dictionary(uniqueKeysWithValues: batch.files.map { ($0.filename, $0) })
        let stillFile = try #require(byName["fixture-0000.jpg"])
        let stillLoad = consume(stillFile)
        #expect(stillLoad.bytes == (try Data(contentsOf: still)))
        #expect(stillLoad.uti == "public.jpeg")
        #expect(stillLoad.subject == "fixture-0000.jpg")

        let videoFile = try #require(byName["video-faststart.mp4"])
        let videoLoad = consume(videoFile)
        #expect(videoLoad.bytes == (try Data(contentsOf: video)))
        #expect(videoLoad.uti == "public.mpeg-4")

        let liveStillFile = try #require(byName["fixture-0002.jpg"])
        #expect(consume(liveStillFile).bytes == (try Data(contentsOf: pairedStill)))
        // The paired video presents under the still's stem with its
        // own UTI-derived extension.
        let liveVideoFile = try #require(byName["fixture-0002.mov"])
        let liveVideoLoad = consume(liveVideoFile)
        #expect(liveVideoLoad.bytes == (try Data(contentsOf: pairedVideo)))
        #expect(liveVideoLoad.uti == "com.apple.quicktime-movie")
        _ = livePhotoItem

        // Completion sweeps the batch — nothing under StagingExport/.
        await vault.coordinator.finishExport(batchID: batch.id)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: vault.container.exportStagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func duplicateFilenamesDedupWithSuffix() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        // Two DIFFERENT images sharing one suggested filename.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let nameA = a.appendingPathComponent("photo.jpg")
        let nameB = b.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(
            at: try TestSupport.fixtureURL("fixture-0000.jpg"), to: nameA)
        try FileManager.default.copyItem(
            at: try TestSupport.fixtureURL("fixture-0002.jpg"), to: nameB)

        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: nameA),
            FixtureMediaProvider(fixtureURL: nameB),
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        _ = await TestSupport.waitUntil { vault.sink.items.count == 2 }

        let result = await vault.coordinator.stageExport(items: vault.sink.items)
        guard case .success(let batch) = result else {
            Issue.record("stageExport failed: \(result)")
            return
        }
        let names = Set(batch.files.map(\.filename))
        #expect(names == ["photo.jpg", "photo (1).jpg"])
        await vault.coordinator.finishExport(batchID: batch.id)
    }

    @Test func midShareLockCancelsAndSweeps() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0004.jpg"))
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        _ = await TestSupport.waitUntil { !vault.sink.items.isEmpty }

        // The share sheet is "up": a staged batch exists.
        let result = await vault.coordinator.stageExport(items: vault.sink.items)
        guard case .success(let batch) = result else {
            Issue.record("stageExport failed: \(result)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: batch.files[0].url.path))

        // Mid-share lock: the export participant sweeps BEFORE the
        // custodian drain — nothing survives under StagingExport/.
        await vault.coordinator.lock()
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: vault.container.exportStagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)

        // And a stage attempted while locked fails typed.
        let lockedResult = await vault.coordinator.stageExport(items: vault.sink.items)
        guard case .failure(.vaultLocked) = lockedResult else {
            Issue.record("expected vaultLocked, got \(lockedResult)")
            return
        }
    }

    @Test func stagingCancellationSweepsAndSettles() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("video-tailmoov.mov"))
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        _ = await TestSupport.waitUntil { !vault.sink.items.isEmpty }
        let items = vault.sink.items
        let controller = ExportController(container: vault.container)
        let reader = try #require(vault.sink.currentReader)

        // Race a cancellation against the staging write. Whichever
        // wins, the custody postcondition must hold: no in-progress
        // export, nothing under StagingExport/ after teardown.
        let plan = items.map {
            ExportPlanItem(
                fileID: $0.id, byteLength: $0.byteLength,
                filename: $0.filename, uti: $0.uti)
        }
        async let staging: Result<ExportBatch, any Error> = {
            do { return .success(try await controller.stage(plan: plan, reader: reader)) }
            catch { return .failure(error) }
        }()
        await controller.cancelActiveExport()
        _ = await staging
        await controller.prepareForLock()
        #expect(await controller.exportInProgress == false)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: vault.container.exportStagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func simulatedCrashRelaunchSweepsExportStaging() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }

        // A crash mid-share strands decrypted plaintext under
        // StagingExport/: plant it, then "relaunch".
        let batchDir = try container.makeExportBatchDirectory()
        let stranded = batchDir.appendingPathComponent("stranded.jpg")
        try Data("EXPORT-CANARY-stranded".utf8).write(to: stranded)

        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let sink = RecordingSink()
        await coordinator.attach(sink: sink)
        await coordinator.start()
        _ = await TestSupport.waitUntil { sink.phase != nil && sink.phase != .starting }

        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: container.exportStagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty, "stranded export plaintext survived relaunch")
    }

    /// The grace/off-preference background override (Codex B4): on
    /// `.background`, REGARDLESS of the auto-lock preference, an
    /// active export cancels and sweeps — the vault itself stays
    /// unlocked under `.off`, proving the override is export-specific.
    @Test func backgroundOverrideFiresUnderOffPolicy() async throws {
        let (store, container) = try await makeStoreWithItem()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lockPreferences.backgroundPolicy = .off

        let batch = await store.beginExport(store.items)
        #expect(batch != nil)
        #expect(store.exportActive)

        store.sceneEnteredBackground()
        #expect(!store.exportActive)
        // The vault did NOT lock (off policy)…
        #expect(store.phase == .unlocked(importing: false))
        // …but the export swept.
        #expect(
            await TestSupport.waitUntil {
                ((try? FileManager.default.contentsOfDirectory(
                    at: container.exportStagingDir, includingPropertiesForKeys: nil)) ?? [])
                    .isEmpty
            })
        #expect(await store.export.exportInProgress == false)
    }

    @Test func backgroundOverrideFiresUnderGracePolicy() async throws {
        let (store, container) = try await makeStoreWithItem()
        defer {
            Task {
                await store.coordinator.teardown()
                TestSupport.removeContainer(container)
            }
        }
        store.lockPreferences.backgroundPolicy = .grace
        store.lockPreferences.gracePeriod = 60  // never trips in-test

        let batch = await store.beginExport(store.items)
        #expect(batch != nil)

        store.sceneEnteredBackground()
        #expect(!store.exportActive)
        #expect(store.phase == .unlocked(importing: false))
        #expect(
            await TestSupport.waitUntil {
                ((try? FileManager.default.contentsOfDirectory(
                    at: container.exportStagingDir, includingPropertiesForKeys: nil)) ?? [])
                    .isEmpty
            })
    }

    @Test func exportStagingCarriesCustodyAttributes() throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        // Backup exclusion is set on the export root (like Staging).
        let values = try? container.exportStagingDir.resourceValues(
            forKeys: [.isExcludedFromBackupKey])
        #expect(values?.isExcludedFromBackup == true)
        #if os(iOS)
            let attrs = try FileManager.default.attributesOfItem(
                atPath: container.exportStagingDir.path)
            if let protection = attrs[.protectionKey] as? FileProtectionType {
                #expect(protection == .completeUnlessOpen)
            }
        #endif
    }

    // MARK: - fixtures

    private func makeStoreWithItem() async throws -> (VaultStore, AppContainer) {
        let container = try TestSupport.makeContainer()
        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let defaults = UserDefaults(suiteName: "export-tests-\(UUID().uuidString)")!
        let store = TestSupport.makeStore(
            coordinator: coordinator, container: container, defaults: defaults)
        await store.bootstrap()
        _ = await TestSupport.waitUntil { store.phase == .needsSetup }
        store.createGallery(password: UnlockedVault.password)
        _ = await TestSupport.waitUntil { store.phase == .unlocked(importing: false) }
        store.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0006.jpg"))
        ])
        _ = await TestSupport.waitUntil { store.lastImportSummary != nil }
        _ = await TestSupport.waitUntil { !store.items.isEmpty }
        return (store, container)
    }
}

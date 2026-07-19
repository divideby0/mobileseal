import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// Import pipeline (GOAL WS B): batch semantics, dedup skip, Live
/// Photo pairs, forced failure, cancellation, provider-error matrix.
@MainActor
@Suite struct ImportPipelineTests {
    private func providers(_ names: [String]) throws -> [any MediaProvider] {
        try names.map { FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL($0)) }
    }

    @Test func batchImportsAndSortsByDate() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        await vault.coordinator.startImport(
            providers: try providers([
                "fixture-0000.jpg", "fixture-0001.heic", "fixture-0002.jpg",
            ]))
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        let summary = try #require(vault.sink.lastSummary)
        #expect(summary.importedCount == 3)
        #expect(summary.failedCount == 0)

        _ = await TestSupport.waitUntil { vault.sink.items.count == 3 }
        let items = vault.sink.items
        #expect(items.count == 3)
        // Every original got a linked encrypted thumbnail.
        #expect(items.allSatisfy { $0.thumbnailID != nil })
        // EXIF dates decoded and sorted newest-first (WS C.2).
        #expect(items.allSatisfy { $0.dateTaken != nil })
        let dates = items.map(\.sortDate)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func duplicateImportSkipsWithNotice() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        await vault.coordinator.startImport(providers: try providers(["fixture-0004.jpg"]))
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })

        // Re-import the same bytes plus a fresh image: the duplicate
        // reports as skipped, the new one lands, and no second entry
        // for the duplicate appears in the grid (grill Q5).
        await vault.coordinator.startImport(
            providers: try providers(["fixture-0004.jpg", "fixture-0006.jpg"]))
        #expect(await TestSupport.waitUntil { vault.sink.summaries.count == 2 })
        let summary = try #require(vault.sink.lastSummary)
        #expect(summary.skippedCount == 1)
        #expect(summary.importedCount == 1)
        _ = await TestSupport.waitUntil { vault.sink.items.count == 2 }
        #expect(vault.sink.items.count == 2)
    }

    @Test func corruptItemFailsAndStopsBatchLeavingCommitted() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        await vault.coordinator.startImport(
            providers: try providers([
                "fixture-0008.jpg", "corrupt-zz.jpg", "fixture-0010.jpg",
            ]))
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        let summary = try #require(vault.sink.lastSummary)

        // Item 0 landed; item 1 failed (undecodable — stored
        // byte-exact but no preview possible); item 2 never attempted
        // (a failed item stops the batch, GOAL WS B.6).
        #expect(summary.importedCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.outcomes[1].status == .failed(.undecodableMedia))
        #expect(summary.outcomes[2].status == .notAttempted)

        // The failed item's original IS committed (byte-exact archive)
        // and shows as thumbnail-less; committed items stay committed.
        _ = await TestSupport.waitUntil { vault.sink.items.count == 2 }
        let noPreview = vault.sink.items.filter { $0.thumbnailID == nil }
        #expect(noPreview.count == 1)
    }

    @Test func providerErrorAndCancelBehaviors() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        var failing = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0012.jpg"))
        failing.behavior = .error("asset unavailable (simulated iCloud failure)")
        var cancelled = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0014.jpg"))
        cancelled.behavior = .cancel

        // Provider-cancel is not a batch failure; provider-error is.
        await vault.coordinator.startImport(providers: [
            cancelled,
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0016.jpg")),
            failing,
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0018.jpg")),
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        let summary = try #require(vault.sink.lastSummary)
        #expect(summary.outcomes[0].status == .notAttempted)
        #expect(summary.importedCount == 1)
        if case .failed(.providerFailed) = summary.outcomes[2].status {
        } else {
            Issue.record("expected providerFailed, got \(summary.outcomes[2].status)")
        }
        #expect(summary.outcomes[3].status == .notAttempted)
    }

    @Test func iCloudDelayBehaviorSucceeds() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        var slow = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0020.jpg"))
        slow.behavior = .delay(0.3)
        await vault.coordinator.startImport(providers: [slow])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        #expect(vault.sink.lastSummary?.importedCount == 1)
    }

    @Test func lockMidBatchCancelsCleansAndReportsInterrupted() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        var slow = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0022.jpg"))
        slow.behavior = .delay(2.0)
        await vault.coordinator.startImport(
            providers: [slow]
                + (try providers(["fixture-0024.jpg", "fixture-0026.jpg"])))
        // Lock while item 0 is still "downloading" (grill Q8:
        // cancel-and-cleanup + resume prompt).
        try? await Task.sleep(for: .milliseconds(200))
        await vault.coordinator.lock()
        #expect(await TestSupport.waitUntil { vault.sink.phase == .locked })
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        let summary = try #require(vault.sink.lastSummary)
        #expect(summary.interrupted)
        #expect(summary.importedCount == 0)
        // Staging wiped by the lock path (gate 4's cancellation leg).
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: vault.container.stagingDir, includingPropertiesForKeys: nil)) ?? []
        #expect(staged.isEmpty)
    }

    @Test func livePhotoImportsBothPartsLinked() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        // A stand-in paired video: the engine treats parts as opaque
        // bytes (byte-exact archive), so any file exercises the link.
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paired-\(UUID().uuidString).mov")
        try Data("not-really-a-movie".utf8).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        var provider = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0028.jpg"))
        provider.pairedVideoURL = videoURL
        await vault.coordinator.startImport(providers: [provider])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        #expect(vault.sink.lastSummary?.importedCount == 1)

        _ = await TestSupport.waitUntil { vault.sink.items.count == 1 }
        let item = try #require(vault.sink.items.first)
        #expect(item.isLivePhotoStill)
        #expect(item.livePhotoVideoID != nil)
        #expect(item.thumbnailID != nil)
    }

    @Test func metadataBlobsRoundTripThroughVault() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        await vault.coordinator.startImport(providers: try providers(["fixture-0030.jpg"]))
        #expect(await TestSupport.waitUntil { vault.sink.items.count == 1 })
        let item = try #require(vault.sink.items.first)
        #expect(item.filename == "fixture-0030.jpg")
        #expect(item.contentHash?.count == 64)
        #expect(item.byteLength > 0)
        #expect(item.pixelWidth == 256)
        #expect(item.pixelHeight == 256)
    }
}

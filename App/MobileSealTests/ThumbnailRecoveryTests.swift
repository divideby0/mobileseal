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
    /// crash between the two), then checks the index reports it and
    /// regeneration heals it.
    @Test func missingThumbnailIsReportedAndRegenerates() async throws {
        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }

        // Bypass the engine: commit only the original (the crash
        // window between the two commits).
        let stillURL = try TestSupport.fixtureURL("fixture-0032.jpg")
        var meta = MediaMetadata(kind: .original, importedAt: Date())
        meta.filename = "fixture-0032.jpg"
        meta.contentHash = try ImportEngine.sha256Hex(of: stillURL)
        let gallery = try #require(await vault.coordinator.debugGallery())
        _ = try await gallery.importFile(at: stillURL, metadata: meta.encoded())

        _ = await TestSupport.waitUntil { vault.sink.items.count == 1 }
        #expect(vault.sink.items[0].thumbnailID == nil)
        #expect(vault.sink.reports.last?.missingThumbnails == 1)

        // Regenerate (the store triggers this from the report).
        await vault.coordinator.regenerateThumbnail(for: vault.sink.items[0].id)
        #expect(
            await TestSupport.waitUntil {
                vault.sink.items.first?.thumbnailID != nil
            })
        #expect(vault.sink.reports.last?.missingThumbnails == 0)
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

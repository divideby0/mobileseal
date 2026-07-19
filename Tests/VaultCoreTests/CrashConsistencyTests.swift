import Foundation
import Testing

@testable import VaultCore

/// Green gate 4 (Codex B8): abort the commit sequence after every step
/// and assert recovery yields the full pre-state or full post-state —
/// never a corrupt vault.
@Suite struct CrashConsistencyTests {
    @Test(arguments: CommitStep.allCases)
    func crashAtStepRecoversToConsistentState(step: CommitStep) async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        // Pre-state: file A committed normally.
        let mediaA = randomBytes(Int(testChunkSize) + 100, seed: 1)
        let mediaB = randomBytes(Int(testChunkSize) * 2 + 55, seed: 2)
        var session = try vault.unlock()
        var gallery = try session.openGallery()
        let fileA = try await gallery.importBytes(mediaA, chunkSize: testChunkSize)

        // Crash while importing B.
        await gallery.setCommitFailpoint(CommitFailpoint(abortAfter: step))
        var crashed = false
        do {
            _ = try await gallery.importBytes(mediaB, chunkSize: testChunkSize)
        } catch is SimulatedCrash {
            crashed = true
        }
        #expect(crashed, "failpoint at \(step) must fire")
        session.lock()

        // "Reboot": reopen from disk; SealedVault init runs recovery.
        session = try vault.unlock()
        let snapshot = session.snapshot()

        // The commit point is the HEAD swap: before it → pre-state,
        // at/after it → post-state.
        let expectPost = step >= .headSwapped
        if expectPost {
            #expect(snapshot.files.count == 2, "crash at \(step): post-state expected")
        } else {
            #expect(snapshot.files.map(\.fileID) == [fileA], "crash at \(step): pre-state expected")
        }

        // Whatever survived must be fully readable (never corrupt).
        let reader = session.makeReader()
        for entry in snapshot.files {
            let expected = entry.unpaddedLength == UInt64(mediaA.count) ? mediaA : mediaB
            #expect(try readAll(reader, fileID: entry.fileID, length: entry.unpaddedLength) == expected)
        }
        // Deep AEAD verification passes on the recovered vault.
        _ = try reader.verifyAuthenticity()

        // Startup recovery removed all WAL staging.
        let walContents = (try? FileManager.default.contentsOfDirectory(
            atPath: vault.layout.walDir.path)) ?? []
        #expect(walContents.isEmpty, "crash at \(step): WAL must be clean after recovery")

        // The vault stays fully usable: a retry of the failed import
        // (new txid, fresh file ID — docs/formats.md §File identity)
        // succeeds and both files read back.
        gallery = try session.openGallery()
        let fileBRetry = try await gallery.importBytes(mediaB, chunkSize: testChunkSize)
        let after = await gallery.snapshot()
        #expect(after.files.count == (expectPost ? 3 : 2))
        let reader2 = await gallery.makeReader()
        #expect(try readAll(reader2, fileID: fileBRetry, length: UInt64(mediaB.count)) == mediaB)
        session.lock()
    }

    @Test func abortedImportLeavesNoTrace() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let session = try vault.unlock()
        let gallery = try session.openGallery()
        // Import from a nonexistent file fails before staging anything.
        await #expect(throws: VaultError.self) {
            _ = try await gallery.importFile(
                at: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
                chunkSize: testChunkSize)
        }
        let snapshot = await gallery.snapshot()
        #expect(snapshot.files.isEmpty)
        let walContents = (try? FileManager.default.contentsOfDirectory(
            atPath: vault.layout.walDir.path)) ?? []
        #expect(walContents.isEmpty)
        session.lock()
    }
}

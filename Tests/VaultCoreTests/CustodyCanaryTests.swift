import Foundation
import Testing

@testable import VaultCore

/// Green gate 3 (Codex B12), scoped to what this harness can observe.
///
/// CLAIM UNDER TEST: no VaultCore API writes plaintext under (a) the
/// vault root or (b) the process temporary directory, across normal
/// operation (create, import via file and bytes, range reads, chunk
/// reads, lock), error paths (wrong password, tampered-chunk read,
/// out-of-bounds read), and simulated-crash recovery (failpoint abort
/// mid-commit + reopen).
///
/// AUDITED PATH SET (stated per Codex B12 — the claim extends no
/// further): every regular file reachable by recursive walk under the
/// vault root and under `FileManager.default.temporaryDirectory`
/// (excluding this test's own source-plaintext file, which necessarily
/// contains the canary; it lives under the temp dir and is removed
/// before the scan). Not audited: swap, core dumps, other processes'
/// caches, filesystem journals, unlinked-but-open files.
@Suite struct CustodyCanaryTests {
    @Test func noPlaintextTouchesDiskAcrossOperationErrorAndCrashPaths() async throws {
        let canary = Array("MSVCANARY-\(UUID().uuidString)-YRANACVSM".utf8)
        var media = randomBytes(Int(testChunkSize) * 2, seed: 55)
        // Plant the canary at chunk 0 start, mid-file, chunk boundary
        // straddle, and tail.
        for at in [
            0, Int(testChunkSize) / 2, Int(testChunkSize) - canary.count / 2,
            media.count - canary.count,
        ] {
            media.replaceSubrange(at..<at + canary.count, with: canary)
        }

        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-canary-src-\(UUID().uuidString)")
        try Data(media).write(to: sourceURL)

        // -- normal operation --
        var session = try vault.unlock()
        var gallery = session.openGallery()
        let viaFile = try await gallery.importFile(
            at: sourceURL, metadata: canary, chunkSize: testChunkSize)
        _ = try await gallery.importBytes(
            randomBytes(1000, seed: 56) + canary, chunkSize: testChunkSize)
        let reader = await gallery.makeReader()
        _ = try readAll(reader, fileID: viaFile, length: UInt64(media.count))
        try reader.withDecryptedChunk(fileID: viaFile, index: 1) { _, _ in () }

        // -- error paths --
        #expect(throws: VaultError.rangeOutOfBounds) {
            try reader.readRange(fileID: viaFile, offset: 0, length: media.count + 1) { _ in () }
        }
        session.lock()
        #expect(throws: VaultError.dekUnwrapFailed) {
            let wrong = try SecureBytes(nfcNormalizedPassword: "wrong")
            _ = try vault.open().unlock(password: wrong)
        }

        // -- simulated crash mid-commit + recovery --
        session = try vault.unlock()
        gallery = session.openGallery()
        await gallery.setCommitFailpoint(CommitFailpoint(abortAfter: .stagedInventoryWritten))
        do {
            _ = try await gallery.importBytes(
                canary + randomBytes(500, seed: 57), chunkSize: testChunkSize)
            Issue.record("failpoint must fire")
        } catch is SimulatedCrash {}
        session.lock()
        session = try vault.unlock()  // reopen runs startup recovery
        // Tampered-chunk read error path, post-recovery.
        let chunkFile = try vault.chunkFiles()[0]
        try vault.tamper(chunkFile, atOffset: ChunkObject.headerLength + 3)
        let reader2 = session.makeReader()
        _ = try? readAll(reader2, fileID: viaFile, length: UInt64(media.count))
        session.lock()

        // Remove the deliberate plaintext source, then audit.
        try FileManager.default.removeItem(at: sourceURL)

        let hits = scan(for: canary, under: [
            vault.directory,
            FileManager.default.temporaryDirectory,
        ])
        #expect(hits.isEmpty, "canary found in: \(hits)")
    }

    /// Recursively scans regular files under `roots` for `needle`.
    private func scan(for needle: [UInt8], under roots: [URL]) -> [String] {
        var hits: [String] = []
        let fm = FileManager.default
        for root in roots {
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [], errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                    values.isRegularFile == true,
                    let size = values.fileSize, size < 512 * 1024 * 1024
                else { continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                if data.range(of: Data(needle)) != nil {
                    hits.append(url.path)
                }
            }
        }
        return hits
    }
}

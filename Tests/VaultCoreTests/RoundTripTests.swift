import Foundation
import Testing

@testable import VaultCore

/// Green gate 1 (round-trip leg): encrypt→decrypt byte-identical across
/// the size matrix, plus wrong-password and persistence across reopen.
@Suite struct RoundTripTests {
    @Test(arguments: [
        0,  // zero-byte file: one padded chunk, no unique fingerprint
        1,  // minimal sub-chunk
        4_000,  // sub-chunk
        Int(testChunkSize),  // exact chunk boundary
        Int(testChunkSize) * 2,  // exact multi-chunk boundary
        Int(testChunkSize) * 2 + 4_097,  // multi-chunk with ragged tail
    ])
    func roundTripByteIdentical(size: Int) async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let original = randomBytes(size, seed: UInt64(size) + 1)
        let session = try vault.unlock()
        let gallery = session.openGallery()
        let fileID = try await gallery.importBytes(
            original, metadata: Array("meta".utf8), chunkSize: testChunkSize)

        let reader = await gallery.makeReader()
        let decrypted = try readAll(reader, fileID: fileID, length: UInt64(size))
        #expect(decrypted == original)

        if size == 0 {
            // Empty file is representable: exactly one padded chunk.
            let snapshot = await gallery.snapshot()
            let entry = snapshot.files.first { $0.fileID == fileID }
            #expect(entry?.chunkCount == 1)
            #expect(entry?.unpaddedLength == 0)
            try reader.withDecryptedChunk(fileID: fileID, index: 0) { _, contentLen in
                #expect(contentLen == 0)
            }
        }
        session.lock()
    }

    @Test func persistsAcrossReopen() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let original = randomBytes(150_000, seed: 7)
        do {
            let session = try vault.unlock()
            let gallery = session.openGallery()
            _ = try await gallery.importBytes(original, chunkSize: testChunkSize)
            session.lock()
        }

        // Fresh SealedVault from disk: startup recovery + meta parse.
        let session = try vault.unlock()
        let snapshot = session.snapshot()
        #expect(snapshot.files.count == 1)
        let entry = try #require(snapshot.files.first)
        #expect(entry.unpaddedLength == 150_000)
        let reader = session.makeReader()
        #expect(try readAll(reader, fileID: entry.fileID, length: entry.unpaddedLength) == original)
        session.lock()
    }

    @Test func wrongPasswordFailsCleanly() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let wrong = try SecureBytes(nfcNormalizedPassword: "not the password")
        #expect(throws: VaultError.dekUnwrapFailed) {
            _ = try vault.open().unlock(password: wrong)
        }
    }

    @Test func importFileStreamsFromDisk() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let original = randomBytes(Int(testChunkSize) * 3 + 5, seed: 99)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-import-src-\(UUID().uuidString)")
        try Data(original).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let session = try vault.unlock()
        let gallery = session.openGallery()
        let fileID = try await gallery.importFile(at: sourceURL, chunkSize: testChunkSize)
        let reader = await gallery.makeReader()
        #expect(try readAll(reader, fileID: fileID, length: UInt64(original.count)) == original)
        session.lock()
    }

    @Test func nfcNormalizationUnifiesPasswordForms() throws {
        // U+00E9 (precomposed) vs U+0065 U+0301 (decomposed) must
        // derive the same key bytes (Codex A5).
        let vault = try TestVault(passwordText: "caf\u{E9} vault")
        defer { vault.destroy() }
        try vault.create()

        let decomposed = try SecureBytes(nfcNormalizedPassword: "cafe\u{301} vault")
        let session = try vault.open().unlock(password: decomposed)
        session.lock()
    }

    @Test func snapshotsCarryNoMetadataAndAccessorsAreSessionScoped() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let secretMetadata = Array("filename=secret.jpg".utf8)
        let session = try vault.unlock()
        let gallery = session.openGallery()
        let fileID = try await gallery.importBytes(
            randomBytes(100, seed: 3), metadata: secretMetadata, chunkSize: testChunkSize)

        // Codex B6: Sendable snapshots expose structure only.
        let snapshot = await gallery.snapshot()
        #expect(snapshot.files.count == 1)
        // (No metadata property exists on FileSummary — enforced by the
        // type; here we assert the accessor path instead.)
        let viaAccessor = try await gallery.metadata(for: fileID)
        #expect(viaAccessor == secretMetadata)

        let reader = await gallery.makeReader()
        #expect(try reader.metadata(for: fileID) == secretMetadata)

        session.lock()
        // Post-lock, metadata accessors fail closed.
        #expect(throws: VaultError.vaultLocked) {
            _ = try reader.metadata(for: fileID)
        }
        await #expect(throws: VaultError.vaultLocked) {
            _ = try await gallery.metadata(for: fileID)
        }
    }
}

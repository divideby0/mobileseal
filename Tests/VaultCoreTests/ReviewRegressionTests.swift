import Foundation
import Testing

@testable import VaultCore

/// Regression locks for wave-001 findings (reviews/wave-001/INDEX.md).
@Suite struct ReviewRegressionTests {
    /// wave-001 claude-code #1: a hostile offset near UInt64.max must
    /// throw `rangeOutOfBounds`, not trap the process.
    @Test func readRangeRefusesOverflowingOffset() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let session = try vault.unlock()
        let gallery = try session.openGallery()
        let fileID = try await gallery.importBytes(
            randomBytes(100, seed: 8), chunkSize: testChunkSize)
        let reader = await gallery.makeReader()

        for offset: UInt64 in [.max, .max - 4, UInt64(Int64.max)] {
            #expect(throws: VaultError.rangeOutOfBounds) {
                try reader.readRange(fileID: fileID, offset: offset, length: 8) { _ in () }
            }
        }
        session.lock()
    }

    /// wave-001 claude-code #2: the single-writer invariant is
    /// structural — a second `openGallery()` throws instead of
    /// silently racing the inventory and dropping an import.
    @Test func secondGalleryIsRefused() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let session = try vault.unlock()
        let g1 = try session.openGallery()
        #expect(throws: VaultError.galleryAlreadyOpen) {
            _ = try session.openGallery()
        }
        // The first gallery is unaffected.
        let id = try await g1.importBytes(randomBytes(10, seed: 9), chunkSize: testChunkSize)
        let snapshot = await g1.snapshot()
        #expect(snapshot.files.map(\.fileID) == [id])
        session.lock()
    }

    /// wave-001 claude-code #3: an oversized object is refused by
    /// stat BEFORE its bytes are materialized.
    @Test func oversizedObjectRefusedBeforeAllocation() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()
        let media = randomBytes(1000, seed: 10)
        do {
            let session = try vault.unlock()
            let gallery = try session.openGallery()
            _ = try await gallery.importBytes(media, chunkSize: testChunkSize)
            session.lock()
        }

        // Grow a chunk object past the maximum legal stored size.
        let url = try vault.chunkFiles()[0]
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Sparse-extend: one byte far past the bound (fast, no 8 MiB
        // write needed — the stat check sees the logical size).
        try handle.seek(toOffset: UInt64(SealedVault.maxStoredChunkBytes) + 1)
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()

        let session = try vault.unlock()
        let reader = session.makeReader()
        let entry = session.snapshot().files[0]
        #expect(throws: VaultError.boundsViolation(.chunk, field: "object_length")) {
            try reader.withDecryptedChunk(fileID: entry.fileID, index: 0) { _, _ in () }
        }
        session.lock()
    }

    /// wave-001 claude-code #13: an empty password is refused, so ""
    /// and "\0" can never derive the same KEK.
    @Test func emptyPasswordIsRefused() {
        #expect(throws: VaultError.emptyPassword) {
            _ = try SecureBytes(nfcNormalizedPassword: "")
        }
    }
}

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

    /// wave-001 claude-code #13 + wave-002 #3: BOTH initializers
    /// refuse empty input, so "" and "\0" can never derive the same
    /// KEK on any path.
    @Test func emptyPasswordIsRefusedOnBothInitializers() {
        #expect(throws: VaultError.emptyPassword) {
            _ = try SecureBytes(nfcNormalizedPassword: "")
        }
        #expect(throws: VaultError.emptyPassword) {
            var empty: [UInt8] = []
            _ = try SecureBytes(consumingAndZeroing: &empty)
        }
    }

    /// wave-002 claude-code #2: `unpadded_length` is bounded like
    /// every other declared length; near-UInt64.max values must throw,
    /// not trap in the chunk-count arithmetic.
    @Test func hostileUnpaddedLengthIsRejected() throws {
        var w = WireWriter()
        w.u64(1)  // generation
        w.u32(1)  // one entry
        w.raw(FileID().wireBytes)
        w.raw(FileID().wireBytes)  // aadFileID
        w.u32(0)  // epoch
        w.u32(testChunkSize)
        w.u64(UInt64.max - 1)  // hostile unpadded_length
        #expect(throws: VaultError.boundsViolation(.inventory, field: "unpadded_length")) {
            _ = try Inventory.parseBody(w.bytes)
        }
    }

    /// wave-002 claude-code #7: the padding validators themselves are
    /// contract enforcement against non-conforming WRITERS — pin them.
    @Test func paddingValidatorEnforcesContract() throws {
        let boundary = Int(VaultFormat.paddingBoundary)
        let unpadded: UInt64 = 100
        let chunk = try SecureBytes(zeroed: boundary)

        // Conforming: 100 content bytes, zero padding to one boundary.
        chunk.withUnsafeMutableBytes { raw in
            for i in 0..<Int(unpadded) { raw[i] = 0xAB }
        }
        try ChunkGeometry.validatePadding(
            chunk: chunk, paddedLen: boundary, index: 0,
            unpaddedLength: unpadded, chunkSize: testChunkSize)

        // Non-zero pad byte → paddingInvalid.
        chunk.withUnsafeMutableBytes { raw in raw[boundary - 1] = 1 }
        #expect(throws: VaultError.paddingInvalid) {
            try ChunkGeometry.validatePadding(
                chunk: chunk, paddedLen: boundary, index: 0,
                unpaddedLength: unpadded, chunkSize: testChunkSize)
        }
        chunk.withUnsafeMutableBytes { raw in raw[boundary - 1] = 0 }

        // Over-padded (one boundary too many) → lengthMismatch.
        #expect(throws: VaultError.lengthMismatch) {
            try ChunkGeometry.validatePadding(
                chunk: chunk, paddedLen: boundary * 2, index: 0,
                unpaddedLength: unpadded, chunkSize: testChunkSize)
        }
    }

    /// wave-002 claude-code #4: format v0 pins the keyring to exactly
    /// one entry — a two-entry keyring is rejected rather than half
    /// read (rotation machinery arrives with the rotation leg).
    @Test func multiEntryKeyringRejectedInV0() throws {
        var w = WireWriter()
        w.raw(FormatV0.metaMagic)
        w.u16(0)
        w.raw(UUID().wireBytes)
        w.u8(1)
        w.u32(3)
        w.u64(256 * 1024 * 1024)
        w.raw([UInt8](repeating: 1, count: 16))
        w.u16(2)  // two entries
        for epoch: UInt32 in [0, 1] {
            w.u32(epoch)
            w.raw([UInt8](repeating: 0, count: 24))
            w.u16(48)
            w.raw([UInt8](repeating: 0, count: 48))
        }
        #expect(throws: VaultError.boundsViolation(.galleryMeta, field: "keyring_entry_count")) {
            _ = try GalleryMeta.parse(w.bytes)
        }
    }

    /// Distinct content must never falsely dedup (renamed per wave-003
    /// claude-code #2 — this asserts a general property; the actual
    /// mutation guards are pinned by `importSourceMutationGuards`).
    @Test func distinctContentDoesNotFalselyDedup() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-toctou-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        try Data(randomBytes(4096, seed: 77)).write(to: sourceURL)

        let session = try vault.unlock()
        let gallery = try session.openGallery()

        // A same-length rewrite between two SEPARATE imports yields
        // distinct entries with distinct chunk sets — no false dedup
        // against the first import's hash.
        let idA = try await gallery.importFile(at: sourceURL, chunkSize: testChunkSize)
        var mutated = randomBytes(4096, seed: 78)
        mutated[0] = 0x5A
        try Data(mutated).write(to: sourceURL)
        let idB = try await gallery.importFile(at: sourceURL, chunkSize: testChunkSize)
        let snapshot = await gallery.snapshot()
        let a = snapshot.files.first { $0.fileID == idA }!
        let b = snapshot.files.first { $0.fileID == idB }!
        #expect(a.chunkAddresses != b.chunkAddresses, "distinct content must not dedup")
        let reader = await gallery.makeReader()
        #expect(try readAll(reader, fileID: idB, length: 4096) == mutated)
        session.lock()
    }
}

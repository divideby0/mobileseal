import Foundation
import Testing

@testable import VaultCore

/// Green gate 1 (dedup leg) and green gate 2 (random access).
@Suite struct DedupAndRandomAccessTests {
    @Test func identicalReimportSharesChunksWithoutRestoring() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let media = randomBytes(Int(testChunkSize) * 2 + 100, seed: 42)
        let session = try vault.unlock()
        let gallery = try session.openGallery()

        let first = try await gallery.importBytes(
            media, metadata: Array("first".utf8), chunkSize: testChunkSize)
        let chunksAfterFirst = try vault.chunkFiles().count

        // Identity = media bytes: same bytes, different metadata.
        let second = try await gallery.importBytes(
            media, metadata: Array("second, different metadata".utf8), chunkSize: testChunkSize)

        // A re-import creates a NEW inventory entry…
        #expect(first != second)
        let snapshot = await gallery.snapshot()
        #expect(snapshot.files.count == 2)
        // …sharing chunks (same addresses, nothing re-stored).
        let e1 = try #require(snapshot.files.first { $0.fileID == first })
        let e2 = try #require(snapshot.files.first { $0.fileID == second })
        #expect(e1.chunkAddresses == e2.chunkAddresses)
        #expect(try vault.chunkFiles().count == chunksAfterFirst)

        // Both entries decrypt to the same bytes; metadata stays per-entry.
        let reader = await gallery.makeReader()
        #expect(try readAll(reader, fileID: second, length: e2.unpaddedLength) == media)
        #expect(try reader.metadata(for: first) == Array("first".utf8))
        #expect(try reader.metadata(for: second) == Array("second, different metadata".utf8))

        // Different content still stores new chunks.
        var other = media
        other[0] ^= 1
        _ = try await gallery.importBytes(other, chunkSize: testChunkSize)
        #expect(try vault.chunkFiles().count > chunksAfterFirst)
        session.lock()
    }

    @Test func midFileRangeReadTouchesOnlyNeededChunks() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let chunks = 5
        let media = randomBytes(Int(testChunkSize) * chunks, seed: 11)
        let session = try vault.unlock()
        let gallery = try session.openGallery()
        let fileID = try await gallery.importBytes(media, chunkSize: testChunkSize)

        let reader = await gallery.makeReader()
        reader.instrumentation.reset()

        // Range spanning exactly chunks 2 and 3 (green gate 2).
        let offset = UInt64(testChunkSize) * 2 + 17
        let length = Int(testChunkSize) - 17 + 1000
        let expected = Array(media[Int(offset)..<Int(offset) + length])
        let got = try reader.readRange(fileID: fileID, offset: offset, length: length) { bytes in
            bytes.withUnsafeBytes { Array($0) }
        }
        #expect(got == expected)
        #expect(reader.instrumentation.decryptCount == 2)  // not chunks, not 5

        // Single-chunk range: exactly one decrypt.
        reader.instrumentation.reset()
        _ = try reader.readRange(fileID: fileID, offset: UInt64(testChunkSize) * 4 + 5, length: 100) {
            _ in ()
        }
        #expect(reader.instrumentation.decryptCount == 1)

        // Out-of-bounds range is refused.
        #expect(throws: VaultError.rangeOutOfBounds) {
            try reader.readRange(
                fileID: fileID, offset: UInt64(media.count) - 10, length: 11
            ) { _ in () }
        }
        session.lock()
    }
}

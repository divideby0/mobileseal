import Foundation
import Testing

@testable import VaultCore

/// Green gate 1: the corruption matrix (Codex B11). Every mutation of
/// authenticated state fails with its documented typed error and never
/// returns plaintext; HEAD damage triggers the documented RECOVERY
/// behavior instead (docs/formats.md §Recovery).
@Suite struct CorruptionMatrixTests {
    /// Builds a vault with one committed file and returns its bytes.
    private func seed(_ vault: TestVault) async throws -> (FileID, [UInt8]) {
        try vault.create()
        let media = randomBytes(Int(testChunkSize) + 500, seed: 21)
        let session = try vault.unlock()
        let gallery = try session.openGallery()
        let fileID = try await gallery.importBytes(media, chunkSize: testChunkSize)
        session.lock()
        return (fileID, media)
    }

    @Test func tamperedChunkCiphertextFailsAEAD() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, media) = try await seed(vault)

        let chunkFile = try #require(try vault.chunkFiles().first)
        try vault.tamper(chunkFile, atOffset: ChunkObject.headerLength + 10)

        let session = try vault.unlock()
        let reader = session.makeReader()
        do {
            _ = try readAll(reader, fileID: fileID, length: UInt64(media.count))
            Issue.record("read of tampered chunk must throw")
        } catch let error as VaultError {
            // One of the two chunks was tampered; whichever it is, the
            // error must be the chunk AEAD failure.
            #expect(error == .authenticationFailed(.chunk))
        }
        session.lock()
    }

    @Test func tamperedChunkHeaderFields() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, _) = try await seed(vault)
        let chunkFiles = try vault.chunkFiles()

        // Magic byte → badMagic.
        try vault.tamper(chunkFiles[0], atOffset: 0)
        // Nonce byte → AEAD failure (nonce participates in decryption).
        try vault.tamper(chunkFiles[1], atOffset: 10)

        let session = try vault.unlock()
        let reader = session.makeReader()
        var seen: Set<VaultError> = []
        for index in 0..<2 {
            do {
                try reader.withDecryptedChunk(fileID: fileID, index: UInt64(index)) { _, _ in
                    Issue.record("tampered chunk \(index) must not decrypt")
                }
            } catch let error as VaultError {
                seen.insert(error)
            }
        }
        #expect(seen.contains(.badMagic(.chunk)))
        #expect(seen.contains(.authenticationFailed(.chunk)))
        session.lock()
    }

    @Test func tamperedChunkVersionIsUnsupported() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, _) = try await seed(vault)

        // version field lives at offset 8..9 (LE). Directory order and
        // chunk order differ, so probe both chunks and require exactly
        // one to fail with the version error.
        try vault.tamper(try vault.chunkFiles()[0], atOffset: 8)

        let session = try vault.unlock()
        let reader = session.makeReader()
        var errors: [VaultError] = []
        for index: UInt64 in [0, 1] {
            do {
                try reader.withDecryptedChunk(fileID: fileID, index: index) { _, _ in () }
            } catch let error as VaultError {
                errors.append(error)
            }
        }
        #expect(errors == [.unsupportedFormatVersion(.chunk, found: 0xFF)])
        session.lock()
    }

    @Test func truncatedChunkIsRejected() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, _) = try await seed(vault)

        let url = try vault.chunkFiles()[0]
        let bytes = [UInt8](try Data(contentsOf: url))
        try Data(bytes.prefix(ChunkObject.headerLength + 100)).write(to: url)

        let session = try vault.unlock()
        let reader = session.makeReader()
        var errors: [VaultError] = []
        for index: UInt64 in [0, 1] {
            do {
                try reader.withDecryptedChunk(fileID: fileID, index: index) { _, _ in () }
            } catch let error as VaultError {
                errors.append(error)
            }
        }
        #expect(errors == [.boundsViolation(.chunk, field: "ciphertext_length")])
        session.lock()
    }

    @Test func missingChunkIsTyped() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, _) = try await seed(vault)

        let url = try vault.chunkFiles()[0]
        let missingAddress = ChunkAddress(hex: url.lastPathComponent)!
        try FileManager.default.removeItem(at: url)

        let session = try vault.unlock()
        let reader = session.makeReader()
        var thrown: VaultError?
        do {
            try reader.withDecryptedChunk(fileID: fileID, index: 0) { _, _ in () }
            // Chunk order in dir listing ≠ chunk order in file; find
            // the missing one by trying both indices.
            try reader.withDecryptedChunk(fileID: fileID, index: 1) { _, _ in () }
        } catch let error as VaultError {
            thrown = error
        }
        #expect(thrown == .missingChunk(missingAddress))
        session.lock()
    }

    @Test func orphanChunkIsHarmlessAndReported() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, media) = try await seed(vault)

        // A well-formed CAS object nobody references.
        let junk = randomBytes(4096, seed: 77)
        let junkAddress = ChunkAddress.compute(over: junk)
        try Data(junk).write(to: vault.layout.chunkURL(junkAddress))

        // Sealed-plane audit: address-consistent, so clean.
        let audit = try vault.open().auditAddresses()
        #expect(audit.mismatchedObjects.isEmpty)

        // Reads are unaffected; deep verify names the orphan.
        let session = try vault.unlock()
        let reader = session.makeReader()
        #expect(try readAll(reader, fileID: fileID, length: UInt64(media.count)) == media)
        let report = try reader.verifyAuthenticity()
        #expect(report.orphanChunks == [junkAddress])
        session.lock()
    }

    @Test func addressMismatchDetectedBySealedAudit() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try await seed(vault)

        let url = try vault.chunkFiles()[0]
        try vault.tamper(url, atOffset: ChunkObject.headerLength + 1)

        let audit = try vault.open().auditAddresses()
        #expect(audit.mismatchedObjects == [url.lastPathComponent])

        // copyChunk re-verifies and refuses.
        let address = ChunkAddress(hex: url.lastPathComponent)!
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dst) }
        do {
            try vault.open().copyChunk(address, to: dst)
            Issue.record("copy of mismatched chunk must throw")
        } catch let error as VaultError {
            if case .addressMismatch(let expected, _) = error {
                #expect(expected == address)
            } else {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    @Test func tamperedKeyringEntryIsIndistinguishableFromWrongPassword() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try await seed(vault)

        // Keyring entry starts at offset 57; wrapped DEK bytes start
        // at 57 + 4 (epoch) + 24 (nonce) + 2 (length).
        try vault.tamper(vault.layout.metaURL, atOffset: 57 + 4 + 24 + 2 + 5)

        #expect(throws: VaultError.dekUnwrapFailed) {
            let pw = try vault.password()
            _ = try vault.open().unlock(password: pw)
        }
    }

    @Test func tamperedMetaMagicAndVersion() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try await seed(vault)

        try vault.tamper(vault.layout.metaURL, atOffset: 0)
        #expect(throws: VaultError.badMagic(.galleryMeta)) {
            _ = try vault.open()
        }

        try vault.tamper(vault.layout.metaURL, atOffset: 0)  // restore
        try vault.tamper(vault.layout.metaURL, atOffset: 9)  // version hi byte
        do {
            _ = try vault.open()
            Issue.record("future meta version must be rejected")
        } catch let error as VaultError {
            #expect(error == .unsupportedFormatVersion(.galleryMeta, found: 0xFF00))
        }
    }

    @Test func oversizedKDFParamsRejectedBeforeAllocation() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try await seed(vault)

        // memlimit u64 at offset 31: set high byte → absurd memlimit.
        try vault.tamper(vault.layout.metaURL, atOffset: 31 + 7)
        #expect(throws: VaultError.kdfParamsOutOfBounds(field: "memlimit")) {
            _ = try vault.open()
        }
    }

    @Test func tamperedInventoryObjectFailsAEADAtUnlock() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try await seed(vault)

        // Tamper the CURRENT inventory (the one HEAD points at) —
        // deliberate tampering is surfaced, not silently rolled back.
        let head = try Head.parse(
            [UInt8](try Data(contentsOf: vault.layout.headURL)))
        try vault.tamper(vault.layout.inventoryURL(head), atOffset: 40)

        #expect(throws: VaultError.authenticationFailed(.inventory)) {
            let pw = try vault.password()
            _ = try vault.open().unlock(password: pw)
        }
    }

    @Test func corruptMissingOrDanglingHEADRecovers() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        let (fileID, media) = try await seed(vault)

        // Corrupt HEAD → recovery to newest valid inventory.
        try Data(randomBytes(Head.length, seed: 5)).write(to: vault.layout.headURL)
        #expect(try vault.open().headState() == .corrupt)
        var session = try vault.unlock()
        #expect(session.snapshot().files.map(\.fileID) == [fileID])
        session.lock()
        // Recovery repaired HEAD.
        let repaired = try vault.open().headState()
        #expect({ if case .valid = repaired { true } else { false } }())

        // Missing HEAD → same recovery.
        try FileManager.default.removeItem(at: vault.layout.headURL)
        session = try vault.unlock()
        let reader = session.makeReader()
        #expect(try readAll(reader, fileID: fileID, length: UInt64(media.count)) == media)
        session.lock()

        // Dangling HEAD (well-formed, target absent) → same recovery.
        let ghost = ChunkAddress(bytes: randomBytes(32, seed: 6))!
        try Data(Head.serialize(ghost)).write(to: vault.layout.headURL)
        #expect(try vault.open().headState() == .dangling(ghost))
        session = try vault.unlock()
        #expect(session.snapshot().files.count == 1)
        session.lock()
    }

    @Test func allInventoriesInvalidIsTyped() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try await seed(vault)

        for url in try vault.inventoryFiles() {
            try vault.tamper(url, atOffset: 40)
        }
        try FileManager.default.removeItem(at: vault.layout.headURL)

        #expect(throws: VaultError.noValidInventory) {
            let pw = try vault.password()
            _ = try vault.open().unlock(password: pw)
        }
    }

    // MARK: - Parser-level bounds (hostile declared lengths, Codex B13/A8)

    @Test func inventoryParserRejectsHostileDeclaredLengths() throws {
        // Oversized entry_count.
        var w = WireWriter()
        w.u64(1)  // generation
        w.u32(FormatV0.maxInventoryEntries + 1)
        #expect(throws: VaultError.boundsViolation(.inventory, field: "entry_count")) {
            _ = try Inventory.parseBody(w.bytes)
        }

        // Oversized metadata_length inside an otherwise valid entry.
        var w2 = WireWriter()
        w2.u64(1)
        w2.u32(1)  // one entry
        w2.raw(FileID().wireBytes)
        w2.raw(FileID().wireBytes)  // aadFileID
        w2.u32(0)  // epoch
        w2.u32(testChunkSize)
        w2.u64(0)  // unpadded length → chunk_count must be 1
        w2.raw([UInt8](repeating: 0, count: 32))  // dedup hash
        w2.u32(1)  // chunk_count
        w2.raw([UInt8](repeating: 0, count: 32))  // address
        w2.u32(FormatV0.maxMetadataBlobBytes + 1)
        #expect(throws: VaultError.boundsViolation(.inventory, field: "metadata_length")) {
            _ = try Inventory.parseBody(w2.bytes)
        }

        // Misaligned chunk size.
        var w3 = WireWriter()
        w3.u64(1)
        w3.u32(1)
        w3.raw(FileID().wireBytes)
        w3.raw(FileID().wireBytes)
        w3.u32(0)
        w3.u32(testChunkSize + 1)  // not a multiple of the boundary
        #expect(throws: VaultError.boundsViolation(.inventory, field: "chunk_size")) {
            _ = try Inventory.parseBody(w3.bytes)
        }

        // chunk_count inconsistent with declared length.
        var w4 = WireWriter()
        w4.u64(1)
        w4.u32(1)
        w4.raw(FileID().wireBytes)
        w4.raw(FileID().wireBytes)
        w4.u32(0)
        w4.u32(testChunkSize)
        w4.u64(UInt64(testChunkSize) * 3)  // needs 3 chunks
        w4.raw([UInt8](repeating: 0, count: 32))
        w4.u32(1)  // declares 1
        #expect(throws: VaultError.boundsViolation(.inventory, field: "chunk_count")) {
            _ = try Inventory.parseBody(w4.bytes)
        }
    }

    @Test func metaParserRejectsMalformedKeyring() throws {
        let galleryID = UUID()
        let salt = [UInt8](repeating: 1, count: 16)

        // wrapped_dek length ≠ 48.
        var w = WireWriter()
        w.raw(FormatV0.metaMagic)
        w.u16(0)
        w.raw(galleryID.wireBytes)
        w.u8(1)
        w.u32(3)
        w.u64(256 * 1024 * 1024)
        w.raw(salt)
        w.u16(1)
        w.u32(0)  // epoch
        w.raw([UInt8](repeating: 0, count: 24))
        w.u16(47)  // bad length
        w.raw([UInt8](repeating: 0, count: 47))
        #expect(throws: VaultError.boundsViolation(.galleryMeta, field: "wrapped_dek_length")) {
            _ = try GalleryMeta.parse(w.bytes)
        }

        // Zero keyring entries.
        var w2 = WireWriter()
        w2.raw(FormatV0.metaMagic)
        w2.u16(0)
        w2.raw(galleryID.wireBytes)
        w2.u8(1)
        w2.u32(3)
        w2.u64(256 * 1024 * 1024)
        w2.raw(salt)
        w2.u16(0)
        #expect(throws: VaultError.boundsViolation(.galleryMeta, field: "keyring_entry_count")) {
            _ = try GalleryMeta.parse(w2.bytes)
        }

        // Trailing bytes are rejected (no smuggled data).
        var w3 = WireWriter()
        w3.raw(FormatV0.metaMagic)
        w3.u16(0)
        w3.raw(galleryID.wireBytes)
        w3.u8(1)
        w3.u32(3)
        w3.u64(256 * 1024 * 1024)
        w3.raw(salt)
        w3.u16(1)
        w3.u32(0)
        w3.raw([UInt8](repeating: 0, count: 24))
        w3.u16(48)
        w3.raw([UInt8](repeating: 0, count: 48))
        w3.u8(0xAA)  // trailing garbage
        #expect(throws: VaultError.boundsViolation(.galleryMeta, field: "trailing bytes")) {
            _ = try GalleryMeta.parse(w3.bytes)
        }
    }
}

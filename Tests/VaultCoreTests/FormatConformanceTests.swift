import Clibsodium
import Foundation
import Testing

@testable import VaultCore

// MARK: - Fixture manifest

struct KATManifest: Codable {
    struct File: Codable {
        let fileID: String  // lowercase UUID string
        let plaintextFile: String?  // nil for the empty file
        let unpaddedLength: UInt64
        let chunkSize: UInt32
        let addresses: [String]
        let metadata: String
    }
    let password: String
    let galleryUUID: String
    let generation: UInt64
    let files: [File]
}

private var katDir: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/kat-vault")
}

// MARK: - Generator (run manually: VAULTCORE_REGEN_FIXTURE=1 swift test)

@Suite struct KATFixtureGenerator {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAULTCORE_REGEN_FIXTURE"] == "1"))
    func regenerate() async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: katDir)
        try fm.createDirectory(at: katDir, withIntermediateDirectories: true)
        let vaultDir = katDir.appendingPathComponent("gallery")

        let password = "kat-password-2026"
        let pw = try SecureBytes(nfcNormalizedPassword: password)
        let vault = try SealedVault.create(at: vaultDir, password: pw, kdfParams: testKDF)

        let mediaA = randomBytes(100_000, seed: 1001)
        try Data(mediaA).write(to: katDir.appendingPathComponent("file-a.bin"))

        let pw2 = try SecureBytes(nfcNormalizedPassword: password)
        let session = try vault.unlock(password: pw2)
        let gallery = try session.openGallery()
        let idA = try await gallery.importBytes(
            mediaA, metadata: Array("name=alpha.jpg".utf8), chunkSize: testChunkSize)
        let idB = try await gallery.importBytes(
            [], metadata: Array("name=empty.dat".utf8), chunkSize: testChunkSize)
        let idC = try await gallery.importBytes(
            mediaA, metadata: Array("name=alpha-again.jpg".utf8), chunkSize: testChunkSize)
        let snapshot = await gallery.snapshot()
        session.lock()

        func fileEntry(_ id: FileID, plaintext: String?, metadata: String) -> KATManifest.File {
            let e = snapshot.files.first { $0.fileID == id }!
            return KATManifest.File(
                fileID: id.uuid.uuidString.lowercased(),
                plaintextFile: plaintext,
                unpaddedLength: e.unpaddedLength,
                chunkSize: e.chunkSize,
                addresses: e.chunkAddresses.map(\.hex),
                metadata: metadata)
        }
        let manifest = KATManifest(
            password: password,
            galleryUUID: vault.meta.galleryID.uuidString.lowercased(),
            generation: snapshot.generation,
            files: [
                fileEntry(idA, plaintext: "file-a.bin", metadata: "name=alpha.jpg"),
                fileEntry(idB, plaintext: nil, metadata: "name=empty.dat"),
                fileEntry(idC, plaintext: "file-a.bin", metadata: "name=alpha-again.jpg"),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(manifest)).write(to: katDir.appendingPathComponent("expected.json"))
        // The throttle sidecar is runtime state, not fixture content.
        try? fm.removeItem(at: vaultDir.appendingPathComponent("unlock.throttle"))
    }
}

// MARK: - Conformance (green gate 7)

/// Decodes the committed fixture vault using ONLY the constants and
/// layouts documented in docs/formats.md — no VaultCore parsing code.
/// Every offset, magic, AAD, bound, and padding rule below is written
/// from the document; if the doc omits something a third-party
/// decryptor needs, this test cannot pass.
@Suite struct FormatConformanceTests {
    // Constants transcribed from docs/formats.md (NOT from FormatV0).
    private static let metaMagic = Array("MSVMETA0".utf8)
    private static let chunkMagic = Array("MSVCHNK0".utf8)
    private static let inventoryMagic = Array("MSVINVN0".utf8)
    private static let headMagic = Array("MSVHEAD0".utf8)
    private static let dekWrapPrefix = Array("mobileseal.dekwrap.v0".utf8) + [0]
    private static let chunkPrefix = Array("mobileseal.chunk.v0".utf8) + [0]
    private static let inventoryPrefix = Array("mobileseal.inventory.v0".utf8) + [0]
    private static let dedupPrefix = Array("mobileseal.dedup.v0".utf8) + [0]
    private static let paddingBoundary = 65536

    private func le16(_ b: ArraySlice<UInt8>) -> UInt16 {
        let a = Array(b)
        return UInt16(a[0]) | (UInt16(a[1]) << 8)
    }
    private func le32(_ b: ArraySlice<UInt8>) -> UInt32 {
        let a = Array(b)
        return (0..<4).reduce(0) { $0 | (UInt32(a[$1]) << (8 * $1)) }
    }
    private func le64(_ b: ArraySlice<UInt8>) -> UInt64 {
        let a = Array(b)
        return (0..<8).reduce(0) { $0 | (UInt64(a[$1]) << (8 * $1)) }
    }
    private func le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    private func blake2b256(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        crypto_generichash(&out, 32, bytes, UInt64(bytes.count), nil, 0)
        return out
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func uuidBytes(_ s: String) -> [UInt8] {
        let u = UUID(uuidString: s)!
        return withUnsafeBytes(of: u.uuid) { Array($0) }
    }

    /// AEAD-open with the documented primitive. Returns nil on tag
    /// failure.
    private func open(ciphertext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: max(ciphertext.count - 16, 1))
        var outLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &out, &outLen, nil, ciphertext, UInt64(ciphertext.count),
            aad, UInt64(aad.count), nonce, key)
        guard rc == 0 else { return nil }
        return Array(out.prefix(Int(outLen)))
    }

    @Test func thirdPartyDecryptRoundTrip() throws {
        #expect(sodium_init() >= 0)
        let manifest = try JSONDecoder().decode(
            KATManifest.self,
            from: try Data(contentsOf: katDir.appendingPathComponent("expected.json")))
        let vaultDir = katDir.appendingPathComponent("gallery")
        let galleryUUID = uuidBytes(manifest.galleryUUID)

        // --- gallery.meta (documented offsets) ---
        let meta = [UInt8](try Data(contentsOf: vaultDir.appendingPathComponent("gallery.meta")))
        #expect(Array(meta[0..<8]) == Self.metaMagic)
        let metaVersion = le16(meta[8..<10])
        #expect(metaVersion == 0)
        #expect(Array(meta[10..<26]) == galleryUUID)
        #expect(meta[26] == 1)  // kdf_alg = Argon2id13
        let opslimit = le32(meta[27..<31])
        let memlimit = le64(meta[31..<39])
        #expect(opslimit >= 1 && opslimit <= 12)
        #expect(memlimit >= 16 << 20 && memlimit <= 1 << 30)
        let salt = Array(meta[39..<55])
        let keyringCount = le16(meta[55..<57])
        #expect(keyringCount == 1)
        #expect(meta.count == 57 + 78 * Int(keyringCount))
        let epoch = le32(meta[57..<61])
        #expect(epoch == 0)
        let wrapNonce = Array(meta[61..<85])
        #expect(le16(meta[85..<87]) == 48)
        let wrappedDEK = Array(meta[87..<135])

        // --- KEK derivation + DEK unwrap ---
        var kek = [UInt8](repeating: 0, count: 32)
        let pwBytes = Array(manifest.password.precomposedStringWithCanonicalMapping.utf8)
        let rc = pwBytes.withUnsafeBufferPointer { pw in
            crypto_pwhash(
                &kek, 32,
                UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self),
                UInt64(pw.count), salt, UInt64(opslimit), Int(memlimit), 2 /* ALG_ARGON2ID13 */)
        }
        #expect(rc == 0)
        let dekWrapAAD = Self.dekWrapPrefix + galleryUUID + le(epoch) + le(metaVersion)
        let dek = try #require(
            open(ciphertext: wrappedDEK, key: kek, nonce: wrapNonce, aad: dekWrapAAD))
        #expect(dek.count == 32)

        // --- HEAD → inventory object ---
        let head = [UInt8](try Data(contentsOf: vaultDir.appendingPathComponent("HEAD")))
        #expect(head.count == 42)
        #expect(Array(head[0..<8]) == Self.headMagic)
        #expect(le16(head[8..<10]) == 0)
        let headAddress = Array(head[10..<42])
        let invPath = vaultDir.appendingPathComponent("manifest/\(hex(headAddress))")
        let invStored = [UInt8](try Data(contentsOf: invPath))
        #expect(blake2b256(invStored) == headAddress, "address = BLAKE2b-256(full stored object)")
        #expect(Array(invStored[0..<8]) == Self.inventoryMagic)
        #expect(le16(invStored[8..<10]) == 0)
        let invNonce = Array(invStored[10..<34])
        let invAAD = Self.inventoryPrefix + galleryUUID + le(epoch) + le(UInt16(0))
        let body = try #require(
            open(ciphertext: Array(invStored[34...]), key: dek, nonce: invNonce, aad: invAAD))

        // --- inventory body (documented field order) ---
        var o = 0
        func take(_ n: Int) -> [UInt8] {
            defer { o += n }
            return Array(body[o..<o + n])
        }
        let generation = le64(body[0..<8])
        o = 8
        #expect(generation == manifest.generation)
        let entryCount = le32(take(4)[...])
        #expect(entryCount == UInt32(manifest.files.count))

        for expected in manifest.files {
            let fileID = take(16)
            let aadFileID = take(16)
            let entryEpoch = le32(take(4)[...])
            let chunkSize = le32(take(4)[...])
            let unpaddedLength = le64(take(8)[...])
            let dedupHash = take(32)
            let chunkCount = le32(take(4)[...])
            var addresses: [[UInt8]] = []
            for _ in 0..<chunkCount { addresses.append(take(32)) }
            let metadataLen = le32(take(4)[...])
            let metadata = take(Int(metadataLen))

            #expect(fileID == uuidBytes(expected.fileID))
            #expect(unpaddedLength == expected.unpaddedLength)
            #expect(chunkSize == expected.chunkSize)
            #expect(addresses.map(hex) == expected.addresses)
            #expect(String(decoding: metadata, as: UTF8.self) == expected.metadata)
            let expectedChunkCount = max(
                1, (unpaddedLength + UInt64(chunkSize) - 1) / UInt64(chunkSize))
            #expect(UInt64(chunkCount) == expectedChunkCount)

            // --- chunks: verify address, decrypt, strip padding ---
            let expectedPlain: [UInt8] =
                try expected.plaintextFile.map {
                    [UInt8](try Data(contentsOf: katDir.appendingPathComponent($0)))
                } ?? []
            var assembled: [UInt8] = []
            for (index, address) in addresses.enumerated() {
                let stored = [UInt8](
                    try Data(
                        contentsOf: vaultDir.appendingPathComponent("chunks/\(hex(address))")))
                #expect(blake2b256(stored) == address)
                #expect(Array(stored[0..<8]) == Self.chunkMagic)
                #expect(le16(stored[8..<10]) == 0)
                let nonce = Array(stored[10..<34])
                let chunkAAD =
                    Self.chunkPrefix + galleryUUID + aadFileID + le(UInt64(index))
                    + le(entryEpoch) + le(UInt16(0))
                let padded = try #require(
                    open(ciphertext: Array(stored[34...]), key: dek, nonce: nonce, aad: chunkAAD),
                    "chunk \(index) must authenticate under the documented AAD")
                // Padding rules: pad to EXACTLY the next boundary
                // multiple (minimum one boundary), zero pad bytes.
                // Exactness matters — a writer that over-pads would
                // otherwise slip through (wave-001 coderabbit).
                let isTail = index == addresses.count - 1
                let content =
                    isTail
                    ? Int(unpaddedLength) - index * Int(chunkSize)
                    : Int(chunkSize)
                let expectedPadded = max(
                    Self.paddingBoundary,
                    (content + Self.paddingBoundary - 1) / Self.paddingBoundary
                        * Self.paddingBoundary)
                #expect(padded.count == expectedPadded)
                #expect(padded[content...].allSatisfy { $0 == 0 }, "pad bytes must be zero")
                assembled.append(contentsOf: padded[0..<content])
            }
            #expect(assembled == expectedPlain, "\(expected.metadata): plaintext round-trip")

            // Dedup hash domain separation (documented prefix).
            #expect(dedupHash == blake2b256(Self.dedupPrefix + expectedPlain))
        }
        #expect(o == body.count, "no undocumented trailing bytes in the inventory body")
    }

    /// The dedup pair shares addresses (identity = media bytes).
    @Test func fixtureDedupPairSharesAddresses() throws {
        let manifest = try JSONDecoder().decode(
            KATManifest.self,
            from: try Data(contentsOf: katDir.appendingPathComponent("expected.json")))
        let alpha = manifest.files.filter { $0.plaintextFile == "file-a.bin" }
        #expect(alpha.count == 2)
        #expect(alpha[0].addresses == alpha[1].addresses)
        #expect(alpha[0].fileID != alpha[1].fileID)
    }

    /// The reference implementation itself also reads the committed
    /// fixture (guards against the generator and decoder agreeing on a
    /// mistake the real reader would reject).
    @Test func referenceImplementationReadsFixture() throws {
        let manifest = try JSONDecoder().decode(
            KATManifest.self,
            from: try Data(contentsOf: katDir.appendingPathComponent("expected.json")))
        let pw = try SecureBytes(nfcNormalizedPassword: manifest.password)
        let vault = try SealedVault(directory: katDir.appendingPathComponent("gallery"))
        let session = try vault.unlock(password: pw)
        let reader = session.makeReader()
        for expected in manifest.files where expected.unpaddedLength > 0 {
            let id = FileID(uuid: UUID(uuidString: expected.fileID)!)
            let plain = try readAll(reader, fileID: id, length: expected.unpaddedLength)
            let want = [UInt8](
                try Data(contentsOf: katDir.appendingPathComponent(expected.plaintextFile!)))
            #expect(plain == want)
        }
        session.lock()
    }
}

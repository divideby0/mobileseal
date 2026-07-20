import Clibsodium
import Foundation
import Testing

@testable import VaultCore

// MARK: - v1 fixture manifest

struct KATV1Manifest: Codable {
    struct File: Codable {
        let fileID: String
        let plaintextFile: String?
        let unpaddedLength: UInt64
        let chunkSize: UInt32
        let addresses: [String]
        let metadata: String
        let migratedFromV0: Bool
    }
    let password: String
    let galleryUUID: String
    let devicePublicKeyHex: String
    let deviceName: String
    let localRevision: UInt64
    let headCounter: UInt64
    /// Entries visible AFTER tombstone application.
    let visibleFiles: [File]
    /// The tombstoned aggregate's file IDs (present as entries +
    /// suppressed by tombstones).
    let tombstonedFileIDs: [String]
}

private var katV1Dir: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/kat-vault-v1")
}

// MARK: - Generator (run manually: VAULTCORE_REGEN_FIXTURE_V1=1 swift test)

/// Builds the committed v1 KAT fixture: the v0 kat-vault MIGRATED by a
/// fresh device, plus an imported two-entry aggregate that is then
/// hard-tombstoned — a migrated vault AND a tombstoned aggregate in
/// one fixture (green gate 3).
@Suite struct KATV1FixtureGenerator {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAULTCORE_REGEN_FIXTURE_V1"] == "1"))
    func regenerate() async throws {
        let fm = FileManager.default
        let v0Gallery = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kat-vault/gallery")
        let v0Expected = try JSONDecoder().decode(
            KATManifest.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("Fixtures/kat-vault/expected.json")))

        try? fm.removeItem(at: katV1Dir)
        try fm.createDirectory(at: katV1Dir, withIntermediateDirectories: true)
        let vaultDir = katV1Dir.appendingPathComponent("gallery")
        try fm.copyItem(at: v0Gallery, to: vaultDir)

        let identity = try DeviceIdentity.generate()
        let rollback = FileRollbackStateStore(
            fileURL: katV1Dir.appendingPathComponent("scratch-rollback.json"))
        let pw = try SecureBytes(nfcNormalizedPassword: v0Expected.password)
        let sealed = try SealedVault(directory: vaultDir)
        let session = try sealed.unlock(
            password: pw, identity: identity, deviceName: "kat-v1-device",
            rollbackStore: rollback)
        let gallery = try session.openGallery()

        // The tombstoned AGGREGATE: an original + linked thumbnail
        // (linkage lives in the app's metadata; the format-level
        // aggregate is simply both entries tombstoned together).
        let aggregateMedia = randomBytes(30_000, seed: 9001)
        let originalID = try await gallery.importBytes(
            aggregateMedia, metadata: Array("name=doomed.jpg".utf8),
            chunkSize: testChunkSize)
        let thumbID = try await gallery.importBytes(
            Array(aggregateMedia.prefix(500)),
            metadata: Array("name=doomed-thumb.jpg".utf8), chunkSize: testChunkSize)
        try await gallery.deleteEntries([originalID, thumbID])

        let manifest = await gallery.debugManifest()
        let snapshot = await gallery.snapshot()
        let counter = try #require(
            try rollback.highWaterMark(
                galleryID: sealed.meta.galleryID, signer: identity.publicKey))
        session.lock()

        let visible = v0Expected.files.map { f -> KATV1Manifest.File in
            let id = FileID(uuid: UUID(uuidString: f.fileID)!)
            precondition(snapshot.files.contains { $0.fileID == id })
            return KATV1Manifest.File(
                fileID: f.fileID, plaintextFile: f.plaintextFile,
                unpaddedLength: f.unpaddedLength, chunkSize: f.chunkSize,
                addresses: f.addresses, metadata: f.metadata, migratedFromV0: true)
        }
        let expected = KATV1Manifest(
            password: v0Expected.password,
            galleryUUID: v0Expected.galleryUUID,
            devicePublicKeyHex: identity.publicKey.hex,
            deviceName: "kat-v1-device",
            localRevision: manifest.localRevision,
            headCounter: counter,
            visibleFiles: visible,
            tombstonedFileIDs: [originalID.description, thumbID.description])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (try encoder.encode(expected)).write(
            to: katV1Dir.appendingPathComponent("expected.json"))
        // file-a.bin for plaintext round-trips.
        try fm.copyItem(
            at: v0Gallery.deletingLastPathComponent().appendingPathComponent("file-a.bin"),
            to: katV1Dir.appendingPathComponent("file-a.bin"))
        // Runtime state is not fixture content.
        try? fm.removeItem(at: vaultDir.appendingPathComponent("unlock.throttle"))
        try? fm.removeItem(at: katV1Dir.appendingPathComponent("scratch-rollback.json"))
    }
}

// MARK: - Conformance (green gate 3)

/// Decodes the committed v1 fixture using ONLY docs/formats.md
/// §Format v1 — documented constants, layouts, signing preambles, and
/// the tombstone application rule; no VaultCore parsing code. If the
/// document omits something a third-party implementation needs, this
/// test cannot pass.
@Suite struct FormatConformanceV1Tests {
    // Constants transcribed from docs/formats.md (NOT from FormatV1).
    private static let manifestMagic = Array("MSVMANF1".utf8)
    private static let headMagic = Array("MSVHEAD1".utf8)
    private static let manifestPrefix = Array("mobileseal.manifest.v1".utf8) + [0]
    private static let headPrefix = Array("mobileseal.head.v1".utf8) + [0]
    private static let addEntrySigDomain = Array("mobileseal.sig.add-entry.v1".utf8) + [0]
    private static let tombstoneSigDomain = Array("mobileseal.sig.tombstone.v1".utf8) + [0]
    private static let trustListSigDomain = Array("mobileseal.sig.trust-list.v1".utf8) + [0]
    private static let headSigDomain = Array("mobileseal.sig.head.v1".utf8) + [0]
    private static let digestDomain = Array("mobileseal.digest.add-entry.v1".utf8) + [0]
    private static let chunkPrefix = Array("mobileseal.chunk.v0".utf8) + [0]
    private static let dekWrapPrefix = Array("mobileseal.dekwrap.v0".utf8) + [0]

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

    private func open(ciphertext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: max(ciphertext.count - 16, 1))
        var outLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &out, &outLen, nil, ciphertext, UInt64(ciphertext.count),
            aad, UInt64(aad.count), nonce, key)
        guard rc == 0 else { return nil }
        return Array(out.prefix(Int(outLen)))
    }

    /// crypto_sign_verify_detached over the documented preamble:
    /// domain ‖ sig_version u16 (=1) ‖ gallery_uuid ‖ payload.
    private func verifySignature(
        _ signature: [UInt8], domain: [UInt8], galleryUUID: [UInt8],
        payload: [UInt8], publicKey: [UInt8]
    ) -> Bool {
        let message = domain + le(UInt16(1)) + galleryUUID + payload
        return crypto_sign_verify_detached(
            signature, message, UInt64(message.count), publicKey) == 0
    }

    @Test func thirdPartyDecodeOfMigratedTombstonedVault() throws {
        #expect(sodium_init() >= 0)
        let expected = try JSONDecoder().decode(
            KATV1Manifest.self,
            from: try Data(contentsOf: katV1Dir.appendingPathComponent("expected.json")))
        let vaultDir = katV1Dir.appendingPathComponent("gallery")
        let galleryUUID = uuidBytes(expected.galleryUUID)
        let devicePK = Array(expected.devicePublicKeyHex.hexDecodedForTest()!)

        // --- gallery.meta → DEK (v0 rules, unchanged in v1) ---
        let meta = [UInt8](try Data(contentsOf: vaultDir.appendingPathComponent("gallery.meta")))
        let salt = Array(meta[39..<55])
        let opslimit = le32(meta[27..<31])
        let memlimit = le64(meta[31..<39])
        let wrapNonce = Array(meta[61..<85])
        let wrappedDEK = Array(meta[87..<135])
        var kek = [UInt8](repeating: 0, count: 32)
        let pwBytes = Array(expected.password.precomposedStringWithCanonicalMapping.utf8)
        let rc = pwBytes.withUnsafeBufferPointer { pw in
            crypto_pwhash(
                &kek, 32,
                UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self),
                UInt64(pw.count), salt, UInt64(opslimit), Int(memlimit), 2)
        }
        #expect(rc == 0)
        let dekWrapAAD = Self.dekWrapPrefix + galleryUUID + le(UInt32(0)) + le(UInt16(0))
        let dek = try #require(
            open(ciphertext: wrappedDEK, key: kek, nonce: wrapNonce, aad: dekWrapAAD))

        // --- HEAD v1: fixed 218 bytes; plaintext address; sealed,
        // signed descriptor ---
        let head = [UInt8](try Data(contentsOf: vaultDir.appendingPathComponent("HEAD")))
        #expect(head.count == 218)
        #expect(Array(head[0..<8]) == Self.headMagic)
        #expect(le16(head[8..<10]) == 1)
        let plainAddress = Array(head[10..<42])
        let headNonce = Array(head[42..<66])
        let headAAD = Self.headPrefix + galleryUUID + le(UInt32(0)) + le(UInt16(1))
        let descriptor = try #require(
            open(ciphertext: Array(head[66...]), key: dek, nonce: headNonce, aad: headAAD))
        #expect(descriptor.count == 136)
        let innerAddress = Array(descriptor[0..<32])
        let headDevice = Array(descriptor[32..<64])
        let headCounter = le64(descriptor[64..<72])
        let headSig = Array(descriptor[72..<136])
        #expect(innerAddress == plainAddress, "spliced HEAD must be detectable")
        #expect(headDevice == devicePK)
        #expect(headCounter == expected.headCounter)
        #expect(
            verifySignature(
                headSig, domain: Self.headSigDomain, galleryUUID: galleryUUID,
                payload: Array(descriptor[0..<72]), publicKey: headDevice),
            "HEAD descriptor signature must verify under the documented preamble")

        // --- Manifest object ---
        let stored = [UInt8](
            try Data(
                contentsOf: vaultDir.appendingPathComponent("manifest/\(hex(plainAddress))")))
        #expect(blake2b256(stored) == plainAddress)
        #expect(Array(stored[0..<8]) == Self.manifestMagic)
        #expect(le16(stored[8..<10]) == 1)
        let mNonce = Array(stored[10..<34])
        let mAAD = Self.manifestPrefix + galleryUUID + le(UInt32(0)) + le(UInt16(1))
        let body = try #require(
            open(ciphertext: Array(stored[34...]), key: dek, nonce: mNonce, aad: mAAD))

        var o = 0
        func take(_ n: Int) -> [UInt8] {
            defer { o += n }
            return Array(body[o..<o + n])
        }
        let localRevision = le64(take(8)[...])
        #expect(localRevision == expected.localRevision)

        // Trust list (documented layout), signature + self-listing.
        let trustPayloadStart = o
        let listVersion = le64(take(8)[...])
        _ = listVersion
        let deviceCount = le32(take(4)[...])
        #expect(deviceCount == 1, "single migrating device in the fixture")
        var trustedKeys: [[UInt8]] = []
        var previousKey: [UInt8]?
        for _ in 0..<deviceCount {
            let pk = take(32)
            if let prev = previousKey {
                #expect(
                    prev.lexicographicallyPrecedes(pk),
                    "trust devices must be strictly ascending")
            }
            previousKey = pk
            trustedKeys.append(pk)
            let role = take(1)[0]
            #expect(role == 1 || role == 2)
            _ = take(8)  // added_at_unix_ms
            let nameLen = Int(le16(take(2)[...]))
            #expect(nameLen <= 256)
            let name = take(nameLen)
            #expect(String(decoding: name, as: UTF8.self) == expected.deviceName)
        }
        let trustSigner = take(32)
        let trustPayload = Array(body[trustPayloadStart..<o])
        let trustSig = take(64)
        #expect(trustedKeys.contains(trustSigner), "trust signer must be self-listed")
        #expect(
            verifySignature(
                trustSig, domain: Self.trustListSigDomain, galleryUUID: galleryUUID,
                payload: trustPayload, publicKey: trustSigner))

        // Entries: strict file_id order, per-entry signature, digest.
        struct DecodedEntry {
            let fileID: [UInt8]
            let aadFileID: [UInt8]
            let epoch: UInt32
            let chunkSize: UInt32
            let unpaddedLength: UInt64
            let addresses: [[UInt8]]
            let metadata: [UInt8]
            let migrated: Bool
            let digest: [UInt8]
        }
        let entryCount = le32(take(4)[...])
        var entries: [DecodedEntry] = []
        var previousID: [UInt8]?
        for _ in 0..<entryCount {
            let payloadStart = o
            let fileID = take(16)
            if let prev = previousID {
                #expect(prev.lexicographicallyPrecedes(fileID), "entries strictly ascending")
            }
            previousID = fileID
            let aadFileID = take(16)
            let epoch = le32(take(4)[...])
            let chunkSize = le32(take(4)[...])
            let unpadded = le64(take(8)[...])
            _ = take(32)  // dedup_hash
            let chunkCount = le32(take(4)[...])
            var addresses: [[UInt8]] = []
            for _ in 0..<chunkCount { addresses.append(take(32)) }
            let metaLen = le32(take(4)[...])
            let metadata = take(Int(metaLen))
            let author = take(32)
            let migratedRaw = take(1)[0]
            #expect(migratedRaw <= 1)
            let payload = Array(body[payloadStart..<o])
            let signature = take(64)
            #expect(
                verifySignature(
                    signature, domain: Self.addEntrySigDomain, galleryUUID: galleryUUID,
                    payload: payload, publicKey: author),
                "entry signature must verify")
            // Canonical digest per the documented construction.
            let digest = blake2b256(
                Self.digestDomain + galleryUUID + payload + signature)
            entries.append(
                DecodedEntry(
                    fileID: fileID, aadFileID: aadFileID, epoch: epoch,
                    chunkSize: chunkSize, unpaddedLength: unpadded,
                    addresses: addresses, metadata: metadata,
                    migrated: migratedRaw == 1, digest: digest))
        }

        // Tombstones: strict canonical-bytes order, signatures.
        struct DecodedTombstone {
            let targetID: [UInt8]
            let digest: [UInt8]?
            let author: [UInt8]
        }
        let tombstoneCount = le32(take(4)[...])
        var tombstones: [DecodedTombstone] = []
        var previousBytes: [UInt8]?
        for _ in 0..<tombstoneCount {
            let payloadStart = o
            let target = take(16)
            let hasDigest = take(1)[0]
            #expect(hasDigest <= 1)
            let digest = hasDigest == 1 ? take(32) : nil
            let author = take(32)
            let payload = Array(body[payloadStart..<o])
            let signature = take(64)
            let storedBytes = payload + signature
            if let prev = previousBytes {
                #expect(
                    prev.lexicographicallyPrecedes(storedBytes),
                    "tombstones strictly ascending")
            }
            previousBytes = storedBytes
            #expect(
                verifySignature(
                    signature, domain: Self.tombstoneSigDomain, galleryUUID: galleryUUID,
                    payload: payload, publicKey: author))
            tombstones.append(
                DecodedTombstone(targetID: target, digest: digest, author: author))
        }
        #expect(o == body.count, "no undocumented trailing bytes in the manifest body")

        // --- Tombstone application per the documented rule ---
        var suppressed: Set<String> = []
        for t in tombstones {
            guard trustedKeys.contains(t.author) else { continue }
            guard let target = entries.first(where: { $0.fileID == t.targetID }) else {
                continue
            }
            if let digest = t.digest, digest != target.digest, !target.migrated {
                continue
            }
            suppressed.insert(hex(t.targetID))
        }
        let visible = entries.filter { !suppressed.contains(hex($0.fileID)) }
        #expect(visible.count == expected.visibleFiles.count)
        #expect(suppressed.count == expected.tombstonedFileIDs.count)
        for id in expected.tombstonedFileIDs {
            #expect(suppressed.contains(hex(uuidBytes(id))))
        }

        // --- Visible entries match the migrated v0 contract and the
        // media still decrypts through documented chunk rules ---
        for want in expected.visibleFiles {
            let idBytes = uuidBytes(want.fileID)
            let entry = try #require(visible.first { $0.fileID == idBytes })
            #expect(entry.migrated == want.migratedFromV0)
            #expect(entry.unpaddedLength == want.unpaddedLength)
            #expect(entry.addresses.map(hex) == want.addresses)
            #expect(String(decoding: entry.metadata, as: UTF8.self) == want.metadata)

            guard let plaintextFile = want.plaintextFile else { continue }
            let expectedPlain = [UInt8](
                try Data(contentsOf: katV1Dir.appendingPathComponent(plaintextFile)))
            var assembled: [UInt8] = []
            for (index, address) in entry.addresses.enumerated() {
                let chunk = [UInt8](
                    try Data(
                        contentsOf: vaultDir.appendingPathComponent("chunks/\(hex(address))")))
                #expect(blake2b256(chunk) == address)
                let nonce = Array(chunk[10..<34])
                let chunkAAD =
                    Self.chunkPrefix + galleryUUID + entry.aadFileID
                    + le(UInt64(index)) + le(entry.epoch) + le(UInt16(0))
                let padded = try #require(
                    open(ciphertext: Array(chunk[34...]), key: dek, nonce: nonce, aad: chunkAAD))
                let isTail = index == entry.addresses.count - 1
                let content =
                    isTail
                    ? Int(entry.unpaddedLength) - index * Int(entry.chunkSize)
                    : Int(entry.chunkSize)
                assembled.append(contentsOf: padded[0..<content])
            }
            #expect(assembled == expectedPlain, "\(want.metadata): plaintext round-trip")
        }
    }

    /// The reference implementation reads the same fixture (guards
    /// against generator+decoder agreeing on a mistake).
    @Test func referenceImplementationReadsV1Fixture() throws {
        let expected = try JSONDecoder().decode(
            KATV1Manifest.self,
            from: try Data(contentsOf: katV1Dir.appendingPathComponent("expected.json")))
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-katv1-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.copyItem(
            at: katV1Dir.appendingPathComponent("gallery"), to: scratch)

        let identity = try DeviceIdentity.generate()
        let rollback = FileRollbackStateStore(
            fileURL: scratch.deletingLastPathComponent()
                .appendingPathComponent("katv1-rollback-\(UUID().uuidString).json"))
        let pw = try SecureBytes(nfcNormalizedPassword: expected.password)
        let session = try SealedVault(directory: scratch).unlock(
            password: pw, identity: identity, deviceName: "kat-reader",
            rollbackStore: rollback)
        let snapshot = session.snapshot()
        #expect(snapshot.generation == expected.localRevision)
        #expect(snapshot.files.count == expected.visibleFiles.count)
        for id in expected.tombstonedFileIDs {
            let fileID = FileID(uuid: UUID(uuidString: id)!)
            #expect(!snapshot.files.contains { $0.fileID == fileID })
        }
        let reader = session.makeReader()
        for want in expected.visibleFiles where want.plaintextFile != nil {
            let id = FileID(uuid: UUID(uuidString: want.fileID)!)
            let plain = try readAll(reader, fileID: id, length: want.unpaddedLength)
            #expect(
                plain
                    == [UInt8](
                        try Data(
                            contentsOf: katV1Dir.appendingPathComponent(want.plaintextFile!))))
        }
        session.lock()
    }
}

extension String {
    /// Hex → bytes for test fixtures (lowercase only, mirrors the
    /// documented canonical form).
    func hexDecodedForTest() -> [UInt8]? {
        Hex.decode(self)
    }
}

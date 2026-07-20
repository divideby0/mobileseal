import Foundation
import Testing

@testable import VaultCore

/// Merge property suite (green gate 1, GOAL WS B.4, review B14):
/// commutativity, associativity, idempotence, tombstone convergence,
/// duplicate-migration convergence — including two-peer fixture
/// histories built through the real vault APIs.
@Suite struct MergePropertyTests {
    let galleryID = UUID(uuidString: "0f0e0d0c-0000-4000-8000-00000000cafe")!

    /// Deterministic pseudo-random state builder: `n` entries and up
    /// to `t` tombstones authored by `identity`.
    func buildState(
        identity: DeviceIdentity, seed: UInt64, entryCount: Int, tombstoneCount: Int,
        sharedFileIDs: [FileID] = []
    ) -> ManifestState {
        var entries: [SignedAddEntry] = []
        for i in 0..<entryCount {
            let fileID = i < sharedFileIDs.count ? sharedFileIDs[i] : FileID()
            let entry = InventoryEntry(
                fileID: fileID, aadFileID: fileID, epoch: 0, chunkSize: 65536,
                unpaddedLength: UInt64(100 + i),
                dedupHash: randomBytes(32, seed: seed &+ UInt64(i)),
                chunkAddresses: [
                    ChunkAddress(bytes: randomBytes(32, seed: seed &+ UInt64(i) &+ 1000))!
                ],
                metadata: Array("m\(i)".utf8))
            entries.append(
                SignedAddEntry.minted(
                    entry: entry, author: identity, migratedFromV0: false,
                    galleryID: galleryID))
        }
        let sortedEntries = entries.sorted {
            $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes)
        }
        var tombstones: [SignedTombstone] = []
        for i in 0..<min(tombstoneCount, entries.count) {
            tombstones.append(
                SignedTombstone.minted(
                    targetFileID: entries[i].fileID,
                    targetDigest: entries[i].canonicalDigest(galleryID: galleryID),
                    author: identity, galleryID: galleryID))
        }
        let trust = SignedTrustList.minted(
            listVersion: 1,
            devices: [
                TrustedDevice(
                    publicKey: identity.publicKey, role: .owner,
                    addedAtUnixMS: 1_700_000_000_000, name: "peer")
            ],
            signer: identity, galleryID: galleryID)
        return ManifestState(
            trustList: trust, entries: sortedEntries,
            tombstones: ManifestState.mergeTombstones(tombstones, []))
    }

    /// Logical content equality: device set, entry set, tombstone set.
    func contentEqual(
        _ a: ManifestState.MergedContent, _ b: ManifestState.MergedContent
    ) -> Bool {
        a.devices == b.devices && a.entries == b.entries && a.tombstones == b.tombstones
            && a.maxTrustListVersion == b.maxTrustListVersion
    }

    /// Lifts merged content back into a state (re-signed trust carrier
    /// by `signer`) so merges can chain for associativity checks.
    func lift(
        _ content: ManifestState.MergedContent, signer: DeviceIdentity
    ) -> ManifestState {
        let devices = SignedTrustList.mergeDevices(
            content.devices,
            [
                TrustedDevice(
                    publicKey: signer.publicKey, role: .member,
                    addedAtUnixMS: 1, name: "merger")
            ])
        return ManifestState(
            trustList: SignedTrustList.minted(
                listVersion: content.maxTrustListVersion,
                devices: devices, signer: signer, galleryID: galleryID),
            entries: content.entries,
            tombstones: content.tombstones)
    }

    @Test func mergeIsCommutative() throws {
        let a = try DeviceIdentity.generate()
        let b = try DeviceIdentity.generate()
        let shared = [FileID(), FileID()]
        let sa = buildState(
            identity: a, seed: 1, entryCount: 5, tombstoneCount: 2, sharedFileIDs: shared)
        let sb = buildState(
            identity: b, seed: 2, entryCount: 4, tombstoneCount: 1, sharedFileIDs: shared)
        let ab = ManifestState.mergeContent(sa, sb, galleryID: galleryID)
        let ba = ManifestState.mergeContent(sb, sa, galleryID: galleryID)
        #expect(contentEqual(ab, ba))
    }

    @Test func mergeIsAssociative() throws {
        let ids = try (0..<3).map { _ in try DeviceIdentity.generate() }
        let shared = [FileID()]
        let states = ids.enumerated().map { i, identity in
            buildState(
                identity: identity, seed: UInt64(i * 100 + 1), entryCount: 3 + i,
                tombstoneCount: i, sharedFileIDs: shared)
        }
        let merger = ids[0]
        let left = ManifestState.mergeContent(
            lift(
                ManifestState.mergeContent(states[0], states[1], galleryID: galleryID),
                signer: merger),
            states[2], galleryID: galleryID)
        let right = ManifestState.mergeContent(
            states[0],
            lift(
                ManifestState.mergeContent(states[1], states[2], galleryID: galleryID),
                signer: merger),
            galleryID: galleryID)
        // Trust carriers differ (different signers en route); the CRDT
        // content must not.
        #expect(left.entries == right.entries)
        #expect(left.tombstones == right.tombstones)
        // Device sets: the merger device joins in both bracketings.
        #expect(left.devices == right.devices)
    }

    @Test func mergeIsIdempotent() throws {
        let a = try DeviceIdentity.generate()
        let sa = buildState(identity: a, seed: 3, entryCount: 6, tombstoneCount: 2)
        let merged = ManifestState.mergeContent(sa, sa, galleryID: galleryID)
        #expect(merged.entries == sa.entries)
        #expect(merged.tombstones == sa.tombstones)
        #expect(merged.devices == sa.trustList.devices)
    }

    @Test func tombstoneConvergenceAcrossDeliveryOrders() throws {
        // Tombstone-before-add: peer B holds a tombstone for an entry
        // it has not seen; merging in either order yields the same
        // effective (suppressed) view.
        let a = try DeviceIdentity.generate()
        let sa = buildState(identity: a, seed: 4, entryCount: 3, tombstoneCount: 0)
        let victim = sa.entries[1]
        let tomb = SignedTombstone.minted(
            targetFileID: victim.fileID,
            targetDigest: victim.canonicalDigest(galleryID: galleryID),
            author: a, galleryID: galleryID)
        var sb = buildState(identity: a, seed: 5, entryCount: 0, tombstoneCount: 0)
        sb.tombstones = [tomb]

        // Alone on B, the tombstone is INERT (target absent).
        let lonely = sb.effectiveView(galleryID: galleryID)
        #expect(lonely.visibleEntries.isEmpty)
        #expect(lonely.inertTombstones == [tomb])

        for (x, y) in [(sa, sb), (sb, sa)] {
            let merged = lift(
                ManifestState.mergeContent(x, y, galleryID: galleryID), signer: a)
            let view = merged.effectiveView(galleryID: galleryID)
            #expect(!view.visibleEntries.contains { $0.fileID == victim.fileID })
            #expect(view.visibleEntries.count == 2)
            #expect(view.inertTombstones.isEmpty, "target appeared — no longer inert")
        }
    }

    @Test func duplicateMigrationConverges() throws {
        // Two devices independently migrate the SAME backed-up v0
        // vault: same file IDs + dedup hashes, different signers. The
        // equivalence rule collapses each pair to one logical entry,
        // identically regardless of merge order (review B8).
        let deviceA = try DeviceIdentity.generate()
        let deviceB = try DeviceIdentity.generate()
        var v0Entries: [InventoryEntry] = []
        for i in 0..<4 {
            let id = FileID()
            let length = UInt64(50 + i)
            let hash: [UInt8] = randomBytes(32, seed: UInt64(i))
            let address = ChunkAddress(bytes: randomBytes(32, seed: UInt64(i + 50)))!
            v0Entries.append(
                InventoryEntry(
                    fileID: id, aadFileID: id, epoch: 0, chunkSize: 65536,
                    unpaddedLength: length, dedupHash: hash,
                    chunkAddresses: [address], metadata: Array("v0-\(i)".utf8)))
        }
        func migrated(by identity: DeviceIdentity) -> ManifestState {
            let entries = v0Entries.map {
                SignedAddEntry.minted(
                    entry: $0, author: identity, migratedFromV0: true, galleryID: galleryID)
            }.sorted { $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes) }
            let trust = SignedTrustList.minted(
                listVersion: 1,
                devices: [
                    TrustedDevice(
                        publicKey: identity.publicKey, role: .owner,
                        addedAtUnixMS: 1, name: "migrator")
                ],
                signer: identity, galleryID: galleryID)
            return ManifestState(trustList: trust, entries: entries, tombstones: [])
        }
        let sa = migrated(by: deviceA)
        let sb = migrated(by: deviceB)
        let ab = ManifestState.mergeContent(sa, sb, galleryID: galleryID)
        let ba = ManifestState.mergeContent(sb, sa, galleryID: galleryID)
        #expect(ab.entries == ba.entries, "order-independent representatives")
        #expect(ab.entries.count == v0Entries.count, "one logical entry per file_id")
        for e in ab.entries {
            #expect(e.migratedFromV0)
            try e.verify(galleryID: galleryID)
        }
        // Both devices survive in the union device set.
        #expect(ab.devices.count == 2)

        // A tombstone minted against A's re-signing still suppresses
        // the collapsed representative even when B's re-signing won.
        let victim = sa.entries[0]
        let tomb = SignedTombstone.minted(
            targetFileID: victim.fileID,
            targetDigest: victim.canonicalDigest(galleryID: galleryID),
            author: deviceA, galleryID: galleryID)
        var withTomb = lift(ab, signer: deviceA)
        withTomb.tombstones = ManifestState.mergeTombstones([tomb], [])
        let view = withTomb.effectiveView(galleryID: galleryID)
        #expect(!view.visibleEntries.contains { $0.fileID == victim.fileID })
        #expect(view.inertTombstones.isEmpty)
    }

    // MARK: - Two-peer histories through the real vault APIs (B14)

    @Test func twoPeerHistoriesConverge() async throws {
        // Peer A: a real v0 vault with content, backed up (copied).
        // Peers A and B each restore the backup, migrate, and mutate
        // independently; their manifest states must merge to the same
        // content both ways.
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.createV0()

        // Seed the v0 world directly (v0 writers no longer exist in
        // the production path).
        let media = randomBytes(60_000, seed: 42)
        try seedV0Entry(vault: vault, media: media, metadata: "shared.jpg")

        // Two restored copies of the same backup.
        let dirA = vault.directory.deletingLastPathComponent()
            .appendingPathComponent("peer-a")
        let dirB = vault.directory.deletingLastPathComponent()
            .appendingPathComponent("peer-b")
        try FileManager.default.copyItem(at: vault.directory, to: dirA)
        try FileManager.default.copyItem(at: vault.directory, to: dirB)

        func mutate(_ dir: URL, name: String, extra: [UInt8]) async throws -> ManifestObject {
            let identity = try DeviceIdentity.generate()
            let store = FileRollbackStateStore(
                fileURL: dir.deletingLastPathComponent()
                    .appendingPathComponent("\(name)-rollback.json"))
            let pw = try vault.password()
            let sealed = try SealedVault(directory: dir)
            let session = try sealed.unlock(
                password: pw, identity: identity, deviceName: name, rollbackStore: store)
            let gallery = try session.openGallery()
            try await gallery.ensureDeviceRegistered()
            _ = try await gallery.importBytes(
                extra, metadata: Array("extra-\(name)".utf8), chunkSize: testChunkSize)
            let manifest = await gallery.debugManifest()
            session.lock()
            return manifest
        }

        let manifestA = try await mutate(dirA, name: "peer-a", extra: randomBytes(2000, seed: 7))
        let manifestB = try await mutate(dirB, name: "peer-b", extra: randomBytes(3000, seed: 8))

        let realGalleryID = try SealedVault(directory: dirA).meta.galleryID
        let ab = ManifestState.mergeContent(
            manifestA.state, manifestB.state, galleryID: realGalleryID)
        let ba = ManifestState.mergeContent(
            manifestB.state, manifestA.state, galleryID: realGalleryID)
        #expect(ab.entries == ba.entries)
        #expect(ab.tombstones == ba.tombstones)
        #expect(ab.devices == ba.devices)
        // The shared migrated entry collapsed to ONE logical entry;
        // each peer's own import survives.
        #expect(ab.entries.filter(\.migratedFromV0).count == 1)
        #expect(ab.entries.count == 3)
        // Device set: both peers (each migrated as owner-genesis).
        #expect(ab.devices.count == 2)
    }
}

/// Seeds one entry into a FORMAT v0 vault by driving the v0 codecs
/// directly (production writers only produce v1 now). Single-chunk
/// small files only — enough for migration fixtures.
func seedV0Entry(vault: TestVault, media: [UInt8], metadata: String) throws {
    precondition(media.count <= 65536)
    let sealed = try vault.open()
    let pw = try vault.password()
    // (deinit zeroes the DEK on scope exit)
    let dek = try sealed.meta.unwrapDEK(password: pw, epoch: 0)
    let layout = vault.layout
    let galleryID = sealed.meta.galleryID

    // Read the current v0 inventory.
    let headBytes = [UInt8](try Data(contentsOf: layout.headURL))
    let address = try Head.parse(headBytes)
    let stored = try FS.read(
        layout.inventoryURL(address), object: .inventory,
        maxBytes: FormatV0.maxInventoryObjectBytes)
    var inventory = try dek.withUnsafeBytes { raw in
        try Inventory.openObject(
            stored: stored, rawDEK: raw, galleryID: galleryID, epoch: 0)
    }

    // Seal the media as one padded chunk.
    let fileID = FileID()
    let paddedLen = max(65536, (media.count + 65535) / 65536 * 65536)
    let buffer = try SecureBytes(zeroed: paddedLen)
    buffer.withUnsafeMutableBytes { raw in
        media.withUnsafeBufferPointer { src in
            raw.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
    }
    let sealedChunk = try ChunkObject.seal(
        plaintext: buffer, plaintextLen: paddedLen, dek: dek,
        galleryID: galleryID, fileID: fileID, chunkIndex: 0, epoch: 0)

    let hasher = CryptoCore.Blake2bStream(domain: FormatV0.dedupDomain)
    hasher.update(media[...])
    inventory.generation += 1
    inventory.entries.append(
        InventoryEntry(
            fileID: fileID, aadFileID: fileID, epoch: 0, chunkSize: 65536,
            unpaddedLength: UInt64(media.count), dedupHash: hasher.finalize(),
            chunkAddresses: [ChunkAddress.compute(over: sealedChunk)],
            metadata: Array(metadata.utf8)))

    let object = try inventory.sealObject(dek: dek, galleryID: galleryID, epoch: 0)
    let tx = try CommitTx(layout: layout)
    _ = try tx.stageChunk(sealedChunk)
    _ = try tx.commit(inventoryObject: object)
}

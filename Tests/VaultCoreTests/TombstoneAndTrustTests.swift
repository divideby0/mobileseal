import Foundation
import Testing

@testable import VaultCore

/// Tombstone matrix (green gate 1): author/owner validity, inert and
/// late-target handling, aggregate tombstoning, delete durability,
/// dedup safety — plus TOFU trust-list behavior (GOAL WS A.2/A.3).
@Suite struct TombstoneAndTrustTests {
    let galleryID = UUID(uuidString: "0badc0de-0000-4000-8000-000000000042")!

    // MARK: - State-level matrix

    private func trustedState(
        owner: DeviceIdentity, extraDevices: [DeviceIdentity] = [],
        entries: [SignedAddEntry] = []
    ) -> ManifestState {
        var devices = [
            TrustedDevice(
                publicKey: owner.publicKey, role: .owner, addedAtUnixMS: 1, name: "owner")
        ]
        for (i, d) in extraDevices.enumerated() {
            devices.append(
                TrustedDevice(
                    publicKey: d.publicKey, role: .member, addedAtUnixMS: 2,
                    name: "member-\(i)"))
        }
        return ManifestState(
            trustList: SignedTrustList.minted(
                listVersion: 1,
                devices: SignedTrustList.mergeDevices(devices, []),
                signer: owner, galleryID: galleryID),
            entries: entries, tombstones: [])
    }

    private func makeEntry(
        author: DeviceIdentity, migrated: Bool = false, seed: UInt64
    ) -> SignedAddEntry {
        let id = FileID()
        return SignedAddEntry.minted(
            entry: InventoryEntry(
                fileID: id, aadFileID: id, epoch: 0, chunkSize: 65536,
                unpaddedLength: 10, dedupHash: randomBytes(32, seed: seed),
                chunkAddresses: [ChunkAddress(bytes: randomBytes(32, seed: seed &+ 9))!],
                metadata: []),
            author: author, migratedFromV0: migrated, galleryID: galleryID)
    }

    @Test func authorTombstoneApplies_untrustedAuthorInert() throws {
        let owner = try DeviceIdentity.generate()
        let member = try DeviceIdentity.generate()
        let stranger = try DeviceIdentity.generate()
        let e1 = makeEntry(author: owner, seed: 1)
        let e2 = makeEntry(author: member, seed: 2)
        var state = trustedState(owner: owner, extraDevices: [member], entries:
            [e1, e2].sorted { $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes) })

        // Author deletes own entry: applies. Member deletes the
        // owner's entry: applies too — single-user semantics, every
        // trusted device passes (the author-or-owner rule's full force
        // arrives with sharing).
        let tombByAuthor = SignedTombstone.minted(
            targetFileID: e2.fileID,
            targetDigest: e2.canonicalDigest(galleryID: galleryID),
            author: member, galleryID: galleryID)
        let tombCrossDevice = SignedTombstone.minted(
            targetFileID: e1.fileID,
            targetDigest: e1.canonicalDigest(galleryID: galleryID),
            author: member, galleryID: galleryID)
        // A tombstone from a key OUTSIDE the trust list stays inert.
        let tombByStranger = SignedTombstone.minted(
            targetFileID: e1.fileID, targetDigest: nil,
            author: stranger, galleryID: galleryID)

        state.tombstones = ManifestState.mergeTombstones(
            [tombByAuthor, tombCrossDevice, tombByStranger], [])
        let view = state.effectiveView(galleryID: galleryID)
        #expect(view.visibleEntries.isEmpty)
        #expect(view.inertTombstones == [tombByStranger].sorted {
            $0.storedBytes.lexicographicallyPrecedes($1.storedBytes)
        } || view.inertTombstones.count == 1)
        #expect(view.inertTombstones.first?.authorPublicKey == stranger.publicKey)
    }

    @Test func digestMismatchRules() throws {
        let owner = try DeviceIdentity.generate()
        let fresh = makeEntry(author: owner, seed: 3)
        let migrated = makeEntry(author: owner, migrated: true, seed: 4)
        var state = trustedState(
            owner: owner,
            entries: [fresh, migrated].sorted {
                $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes)
            })

        let wrongDigest = randomBytes(32, seed: 99)
        // Mismatched digest on a NON-migrated entry: inert + reported
        // (the tombstone names a signed object this is not).
        let inertTomb = SignedTombstone.minted(
            targetFileID: fresh.fileID, targetDigest: wrongDigest,
            author: owner, galleryID: galleryID)
        // Mismatched digest on a MIGRATED entry: applies — the
        // equivalence class spans re-signings (review B8), so the
        // digest may name the OTHER peer's representative.
        let applyingTomb = SignedTombstone.minted(
            targetFileID: migrated.fileID, targetDigest: wrongDigest,
            author: owner, galleryID: galleryID)
        state.tombstones = ManifestState.mergeTombstones([inertTomb, applyingTomb], [])

        let view = state.effectiveView(galleryID: galleryID)
        #expect(view.visibleEntries.map(\.fileID) == [fresh.fileID])
        #expect(view.inertTombstones.count == 1)
        #expect(view.inertTombstones.first?.targetFileID == fresh.fileID)
    }

    // MARK: - Gallery-level delete (aggregate, durable, dedup-safe)

    @Test func aggregateDeleteHidesEntriesAndSurvivesRelaunch() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()

        var session = try vault.unlock()
        var gallery = try session.openGallery()
        let original = try await gallery.importBytes(
            randomBytes(4000, seed: 1), metadata: Array("original".utf8),
            chunkSize: testChunkSize)
        let thumb = try await gallery.importBytes(
            randomBytes(500, seed: 2), metadata: Array("thumb".utf8), chunkSize: testChunkSize)
        let keeper = try await gallery.importBytes(
            randomBytes(600, seed: 3), metadata: Array("keeper".utf8), chunkSize: testChunkSize)

        // Delete the aggregate (original + linked thumbnail) in one
        // call — one commit, both gone.
        let before = await gallery.snapshot().generation
        try await gallery.deleteEntries([original, thumb])
        let after = await gallery.snapshot()
        #expect(after.generation == before + 1)
        #expect(after.files.map(\.fileID) == [keeper])
        // Chunks stay on disk — space reclaim is the GC leg's.
        #expect(try !vault.chunkFiles().isEmpty)
        session.lock()

        // Durable across relaunch.
        session = try vault.unlock()
        #expect(session.snapshot().files.map(\.fileID) == [keeper])
        // Deleted entries are unreadable (typed).
        let reader = session.makeReader()
        #expect(throws: VaultError.fileNotFound(original)) {
            try reader.metadata(for: original)
        }
        gallery = try session.openGallery()
        // Idempotent: deleting again is a no-op commit-wise.
        let revision = await gallery.snapshot().generation
        try await gallery.deleteEntries([original, thumb])
        #expect(await gallery.snapshot().generation == revision)
        session.lock()
    }

    @Test func deletingOneDedupTwinKeepsTheOtherReadable() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()

        let session = try vault.unlock()
        let gallery = try session.openGallery()
        let media = randomBytes(30_000, seed: 11)
        let first = try await gallery.importBytes(
            media, metadata: Array("first".utf8), chunkSize: testChunkSize)
        let twin = try await gallery.importBytes(
            media, metadata: Array("twin".utf8), chunkSize: testChunkSize)

        try await gallery.deleteEntries([first])
        let snapshot = await gallery.snapshot()
        #expect(snapshot.files.map(\.fileID) == [twin])
        // The twin still decrypts through the SHARED chunks (sealed
        // under the first importer's aad_file_id).
        let reader = await gallery.makeReader()
        #expect(try readAll(reader, fileID: twin, length: UInt64(media.count)) == media)
        session.lock()
    }

    // MARK: - TOFU trust list (WS A.2/A.3)

    @Test func newDeviceSelfRegistersOnFirstWriteCapableUnlock() async throws {
        // Device migration/restore behavior (review B12): a restored
        // vault without its original Keychain key enrolls as a NEW
        // device via TOFU; old entries stay valid under the old
        // pubkey.
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()

        var session = try vault.unlock()
        var gallery = try session.openGallery()
        let media = randomBytes(5000, seed: 21)
        let imported = try await gallery.importBytes(
            media, metadata: Array("from-old-device".utf8), chunkSize: testChunkSize)
        session.lock()

        // "Restored to a replacement device": same vault bytes, fresh
        // identity, fresh device-local state.
        let newIdentity = try DeviceIdentity.generate()
        let newStore = FileRollbackStateStore(
            fileURL: vault.directory.deletingLastPathComponent()
                .appendingPathComponent("new-device-rollback.json"))
        session = try vault.unlock(
            as: newIdentity, named: "replacement-device", rollbackStore: newStore)
        gallery = try session.openGallery()
        #expect(await !gallery.isDeviceRegistered)
        try await gallery.ensureDeviceRegistered()
        #expect(await gallery.isDeviceRegistered)
        let devices = await gallery.trustedDevices()
        #expect(devices.count == 2)
        #expect(devices.contains { $0.publicKey == newIdentity.publicKey })

        // Old entries remain valid under the old pubkey; the new
        // device reads and can DELETE them (single-user semantics).
        let reader = await gallery.makeReader()
        #expect(try readAll(reader, fileID: imported, length: UInt64(media.count)) == media)
        try await gallery.deleteEntries([imported])
        #expect(await gallery.snapshot().files.isEmpty)
        session.lock()
    }

    @Test func registrationFoldsIntoFirstMutationCommit() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()
        var session = try vault.unlock()
        session.lock()

        let newIdentity = try DeviceIdentity.generate()
        let newStore = FileRollbackStateStore(
            fileURL: vault.directory.deletingLastPathComponent()
                .appendingPathComponent("fold-rollback.json"))
        session = try vault.unlock(
            as: newIdentity, named: "folded-device", rollbackStore: newStore)
        let gallery = try session.openGallery()
        // No explicit registration: the first import commit carries it.
        _ = try await gallery.importBytes(
            randomBytes(100, seed: 31), metadata: [], chunkSize: testChunkSize)
        #expect(await gallery.isDeviceRegistered)
        let manifest = await gallery.debugManifest()
        #expect(manifest.state.trustList.listVersion == 2)
        #expect(manifest.state.trustList.devices.count == 2)
        // The newcomer registers as MEMBER; genesis owner persists.
        let roles = Dictionary(
            uniqueKeysWithValues: manifest.state.trustList.devices.map {
                ($0.publicKey, $0.role)
            })
        #expect(roles[newIdentity.publicKey] == .member)
        #expect(roles.values.contains(.owner))
        session.lock()
    }
}

/// Rollback detector (green gate 1, GOAL WS B.7): fires on a stale
/// counter from a KNOWN signer; re-baselines through the RECORDED
/// acceptance path; unknown signers (fresh devices) never fire.
@Suite struct RollbackDetectorTests {
    @Test func detectorFiresOnStaleCounterAndAcceptanceRebaselines() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()

        // Commit 1: an import.
        var session = try vault.unlock()
        var gallery = try session.openGallery()
        _ = try await gallery.importBytes(
            randomBytes(800, seed: 41), metadata: [], chunkSize: testChunkSize)
        session.lock()

        // "iCloud backup" of the vault at this point.
        let backup = vault.directory.deletingLastPathComponent()
            .appendingPathComponent("backup")
        try FileManager.default.copyItem(at: vault.directory, to: backup)

        // Commit 2 moves the counter past the backup's.
        session = try vault.unlock()
        gallery = try session.openGallery()
        _ = try await gallery.importBytes(
            randomBytes(900, seed: 42), metadata: [], chunkSize: testChunkSize)
        session.lock()

        // Restore the older backup: KNOWN signer, stale counter.
        try FileManager.default.removeItem(at: vault.directory)
        try FileManager.default.copyItem(at: backup, to: vault.directory)

        do {
            _ = try vault.unlock()
            Issue.record("expected manifestRolledBack")
        } catch let VaultError.manifestRolledBack(presented, highWater) {
            #expect(presented < highWater)
        }

        // The user-visible acceptance flow: re-baseline + RECORD.
        session = try vault.unlock(acceptRollback: true)
        #expect(session.snapshot().files.count == 1)
        session.lock()
        let galleryID = try vault.open().meta.galleryID
        let acceptances = try vault.rollbackStore.acceptances(galleryID: galleryID)
        #expect(acceptances.count == 1)
        #expect(acceptances.first?.presentedCounter ?? 0 < acceptances.first?.previousHighWaterMark ?? 0)

        // After re-baselining, subsequent unlocks are clean.
        session = try vault.unlock()
        session.lock()
    }

    @Test func unknownSignerNeverFires() async throws {
        // A replacement device (fresh device-local state) restoring an
        // OLD backup sees a signer it has never observed — TOFU: no
        // fire, no false rollback block (review B10/B12).
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()
        var session = try vault.unlock()
        let gallery = try session.openGallery()
        _ = try await gallery.importBytes(
            randomBytes(700, seed: 51), metadata: [], chunkSize: testChunkSize)
        session.lock()

        let freshIdentity = try DeviceIdentity.generate()
        let freshStore = FileRollbackStateStore(
            fileURL: vault.directory.deletingLastPathComponent()
                .appendingPathComponent("fresh-device.json"))
        session = try vault.unlock(
            as: freshIdentity, named: "fresh", rollbackStore: freshStore)
        #expect(session.snapshot().files.count == 1)
        session.lock()
    }

    @Test func ownCommitsNeverFireTheDetector() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()
        for i in 0..<3 {
            let session = try vault.unlock()
            let gallery = try session.openGallery()
            _ = try await gallery.importBytes(
                randomBytes(100 + i, seed: UInt64(60 + i)), metadata: [],
                chunkSize: testChunkSize)
            session.lock()
        }
        let session = try vault.unlock()
        #expect(session.snapshot().files.count == 3)
        session.lock()
    }
}

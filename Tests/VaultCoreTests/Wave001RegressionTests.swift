import Foundation
import Testing

@testable import VaultCore

/// Regression pins for CED-13 review wave-001's merged findings.
@Suite struct Wave001RegressionTests {
    let galleryID = UUID(uuidString: "0f00ba55-0000-4000-8000-0000000000aa")!

    /// codex #2: an INERT tombstone (untrusted author, or mismatched
    /// digest on a non-migrated entry) must not make a later VALID
    /// delete a no-op.
    @Test func inertTombstonesDoNotBlockValidDeletes() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()

        let session = try vault.unlock()
        let gallery = try session.openGallery()
        let victimA = try await gallery.importBytes(
            randomBytes(300, seed: 1), metadata: [], chunkSize: testChunkSize)
        let victimB = try await gallery.importBytes(
            randomBytes(400, seed: 2), metadata: [], chunkSize: testChunkSize)

        // Simulate merged-in inert tombstones: one from an UNTRUSTED
        // key targeting A, one from the trusted device with a WRONG
        // digest targeting B. Both are retained-but-inert.
        let stranger = try DeviceIdentity.generate()
        var manifest = await gallery.debugManifest()
        let realGalleryID = gallery.galleryID
        let inertUntrusted = SignedTombstone.minted(
            targetFileID: victimA, targetDigest: nil,
            author: stranger, galleryID: realGalleryID)
        let inertWrongDigest = SignedTombstone.minted(
            targetFileID: victimB, targetDigest: randomBytes(32, seed: 3),
            author: vault.identity, galleryID: realGalleryID)
        manifest.state.tombstones = ManifestState.mergeTombstones(
            [inertUntrusted, inertWrongDigest], [])
        await gallery.debugReplaceManifest(manifest)

        // Both entries are still VISIBLE (tombstones inert)…
        #expect(await gallery.snapshot().files.count == 2)
        // …and a legitimate delete must still work.
        try await gallery.deleteEntries([victimA, victimB])
        #expect(await gallery.snapshot().files.isEmpty)
        session.lock()
    }

    /// claude-code #1 / codex #5: recovery must not persist a HEAD
    /// signed by a device the recovered manifest does not trust — the
    /// unlisted device proceeds in memory and the repaired HEAD is
    /// written by its registration commit instead.
    @Test func recoveryByUnlistedDeviceDoesNotWriteRejectedHead() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        _ = try vault.create()
        var session = try vault.unlock()
        let gallery = try session.openGallery()
        _ = try await gallery.importBytes(
            randomBytes(600, seed: 4), metadata: [], chunkSize: testChunkSize)
        session.lock()

        // Replacement device (fresh identity + fresh device-local
        // state) finds a vault with a DAMAGED HEAD.
        try FileManager.default.removeItem(
            at: vault.directory.appendingPathComponent("HEAD"))
        let newIdentity = try DeviceIdentity.generate()
        let newStore = FileRollbackStateStore(
            fileURL: vault.directory.deletingLastPathComponent()
                .appendingPathComponent("unlisted-recovery.json"))

        // Read-only unlock: recovery succeeds in memory, but no HEAD
        // signed by the unlisted device may be persisted.
        session = try vault.unlock(
            as: newIdentity, named: "replacement", rollbackStore: newStore)
        #expect(session.snapshot().files.count == 1)
        session.lock()

        // A SECOND unlock must not be rejected as tampering — either
        // the HEAD is still absent (recovery re-runs) or whatever was
        // written passes the untrusted-signer check.
        session = try vault.unlock(
            as: newIdentity, named: "replacement", rollbackStore: newStore)
        #expect(session.snapshot().files.count == 1)
        session.lock()

        // Once the device registers (write-capable path), the commit
        // publishes a consistent HEAD and subsequent unlocks are
        // ordinary v1 loads.
        session = try vault.unlock(
            as: newIdentity, named: "replacement", rollbackStore: newStore)
        let g2 = try session.openGallery()
        try await g2.ensureDeviceRegistered()
        session.lock()
        session = try vault.unlock(
            as: newIdentity, named: "replacement", rollbackStore: newStore)
        #expect(session.snapshot().files.count == 1)
        session.lock()
    }

    /// codex #3: writer-side trust-list bounds — an over-long device
    /// name is canonicalized to the wire bound instead of committing
    /// a manifest the parser rejects.
    @Test func overlongDeviceNamesAreCanonicalizedNotCommittedBroken() async throws {
        let longName = String(repeating: "é", count: 200)  // 400 UTF-8 bytes
        #expect(longName.utf8.count > FormatV1.maxDeviceNameBytes)
        let truncated = SignedTrustList.canonicalName(longName)
        #expect(truncated.utf8.count <= FormatV1.maxDeviceNameBytes)
        #expect(longName.hasPrefix(truncated))

        // End-to-end: create + reopen a vault whose device name is
        // over the bound — round-trips because the writer truncated.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave001-longname-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("gallery")
        let identity = try DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: root.appendingPathComponent("rollback.json"))
        var pw = Array("wave-001 password".utf8)
        _ = try SealedVault.create(
            at: dir, password: SecureBytes(consumingAndZeroing: &pw),
            kdfParams: testKDF, identity: identity, deviceName: longName)
        var pw2 = Array("wave-001 password".utf8)
        let session = try SealedVault(directory: dir).unlock(
            password: SecureBytes(consumingAndZeroing: &pw2),
            identity: identity, deviceName: longName, rollbackStore: store)
        #expect(session.manifest.state.trustList.devices[0].name.utf8.count
            <= FormatV1.maxDeviceNameBytes)
        session.lock()
    }

    /// coderabbit: a rollback-state file that EXISTS but cannot be
    /// decoded surfaces a typed error instead of silently resetting
    /// every signer to the never-fires TOFU path.
    @Test func corruptRollbackStateSurfacesInsteadOfSilentTOFUReset() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave001-corrupt-rollback-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let store = FileRollbackStateStore(fileURL: url)
        let signer = try DeviceIdentity.generate().publicKey
        #expect(throws: VaultError.ioFailure(
            operation: "decode rollback state", path: url.path)
        ) {
            _ = try store.highWaterMark(galleryID: UUID(), signer: signer)
        }
    }
}

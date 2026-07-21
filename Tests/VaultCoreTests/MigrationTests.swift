import Foundation
import Testing

@testable import VaultCore

/// v0 → v1 migration state machine (green gate 1, GOAL WS B.6):
/// contract preservation over the committed v0 KAT fixture, crash
/// injection at every migration step AND every commit sub-step, and
/// idempotent re-runs.
@Suite struct MigrationTests {
    private var katGallery: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kat-vault/gallery")
    }

    private var katManifest: KATManifest {
        get throws {
            try JSONDecoder().decode(
                KATManifest.self,
                from: Data(
                    contentsOf: URL(fileURLWithPath: #filePath)
                        .deletingLastPathComponent()
                        .appendingPathComponent("Fixtures/kat-vault/expected.json")))
        }
    }

    /// A scratch copy of the committed v0 fixture — "a backed-up v0
    /// vault", exactly the migration input review B8 names.
    private func scratchCopy() throws -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-tests-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("gallery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: katGallery, to: dir)
        return (dir, { try? FileManager.default.removeItem(at: root) })
    }

    private func unlockFixture(
        _ dir: URL, identity: DeviceIdentity, store: FileRollbackStateStore,
        migrationFailpoint: MigrationFailpoint = .none,
        commitFailpoint: CommitFailpoint = .none
    ) throws -> UnlockSession {
        let pw = try SecureBytes(nfcNormalizedPassword: try katManifest.password)
        return try SealedVault(directory: dir).unlockInternal(
            password: pw, identity: identity, deviceName: "migrator",
            rollbackStore: store,
            migrationFailpoint: migrationFailpoint, commitFailpoint: commitFailpoint)
    }

    @Test func migrationPreservesTheStorageContract() throws {
        let (dir, cleanup) = try scratchCopy()
        defer { cleanup() }
        let expected = try katManifest
        let identity = try DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: dir.deletingLastPathComponent().appendingPathComponent("rollback.json"))

        let session = try unlockFixture(dir, identity: identity, store: store)
        let snapshot = session.snapshot()

        // Local revision = v0 generation + 1 (shared recovery axis).
        #expect(snapshot.generation == expected.generation + 1)
        // Every v0 entry survives with identity, geometry, and
        // addresses verbatim (B2: file_id, aad_file_id, chunk list,
        // sizes all preserved).
        #expect(snapshot.files.count == expected.files.count)
        for want in expected.files {
            let id = FileID(uuid: UUID(uuidString: want.fileID)!)
            let got = try #require(snapshot.files.first { $0.fileID == id })
            #expect(got.unpaddedLength == want.unpaddedLength)
            #expect(got.chunkSize == want.chunkSize)
            #expect(got.chunkAddresses.map(\.hex) == want.addresses)
        }
        // Plaintext still decrypts through shared dedup chunks.
        let reader = session.makeReader()
        for want in expected.files where want.unpaddedLength > 0 {
            let id = FileID(uuid: UUID(uuidString: want.fileID)!)
            let plain = try readAll(reader, fileID: id, length: want.unpaddedLength)
            let file = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/kat-vault/\(want.plaintextFile!)")
            #expect(plain == [UInt8](try Data(contentsOf: file)))
        }
        // Manifest internals: all entries migrated + authored by this
        // device; genesis trust list = [self as owner].
        #expect(session.manifest.state.entries.allSatisfy { $0.migratedFromV0 })
        #expect(
            session.manifest.state.entries.allSatisfy {
                $0.authorPublicKey == identity.publicKey
            })
        #expect(session.manifest.state.trustList.devices.count == 1)
        #expect(session.manifest.state.trustList.devices[0].role == .owner)
        // v0 metadata blobs ride along verbatim.
        for want in expected.files {
            let id = FileID(uuid: UUID(uuidString: want.fileID)!)
            let entry = session.manifest.state.entries.first { $0.fileID == id }!
            #expect(entry.entry.metadata == Array(want.metadata.utf8))
        }
        session.lock()

        // HEAD is now v1; the v0 object was superseded at the commit
        // point (its file may remain in the CAS — GC-leg concern).
        let headBytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent("HEAD")))
        let parsed = try HeadFile.parse(headBytes)
        guard case .v1 = parsed else {
            Issue.record("expected v1 HEAD after migration")
            return
        }
    }

    @Test(arguments: MigrationStep.allCases)
    func crashInjectionAtMigrationStep(_ step: MigrationStep) throws {
        let (dir, cleanup) = try scratchCopy()
        defer { cleanup() }
        let expected = try katManifest
        let identity = try DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: dir.deletingLastPathComponent().appendingPathComponent("rollback.json"))

        do {
            _ = try unlockFixture(
                dir, identity: identity, store: store,
                migrationFailpoint: MigrationFailpoint(abortAfter: step))
            // Steps after the commit point complete the unlock only if
            // nothing threw — all listed steps DO throw here.
            Issue.record("failpoint \(step) did not fire")
        } catch is SimulatedMigrationCrash {
            // expected
        }

        // Re-run: the machine converges to exactly one migrated world.
        let session = try unlockFixture(dir, identity: identity, store: store)
        #expect(session.snapshot().generation == expected.generation + 1)
        #expect(session.snapshot().files.count == expected.files.count)
        #expect(session.manifest.state.entries.count == expected.files.count)
        #expect(session.manifest.state.trustList.listVersion == 1)
        session.lock()
    }

    @Test(arguments: CommitStep.allCases)
    func crashInjectionAtCommitStep(_ step: CommitStep) throws {
        let (dir, cleanup) = try scratchCopy()
        defer { cleanup() }
        let expected = try katManifest
        let identity = try DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: dir.deletingLastPathComponent().appendingPathComponent("rollback.json"))

        do {
            _ = try unlockFixture(
                dir, identity: identity, store: store,
                commitFailpoint: CommitFailpoint(abortAfter: step))
            Issue.record("commit failpoint \(step) did not fire")
        } catch is SimulatedCrash {
            // expected — vault left exactly as a crash at that step
        }

        // Re-open runs WAL recovery; unlock converges. Pre-commit-
        // point crashes leave the v0 world (migration re-runs); post-
        // commit-point crashes leave the committed v1 world.
        let session = try unlockFixture(dir, identity: identity, store: store)
        #expect(session.snapshot().generation == expected.generation + 1)
        #expect(session.snapshot().files.count == expected.files.count)
        let entries = session.manifest.state.entries
        #expect(entries.count == expected.files.count, "exactly-once migration")
        #expect(Set(entries.map(\.fileID)).count == entries.count)
        session.lock()
    }

    @Test func reRunningACompletedMigrationIsANoOp() throws {
        let (dir, cleanup) = try scratchCopy()
        defer { cleanup() }
        let identity = try DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: dir.deletingLastPathComponent().appendingPathComponent("rollback.json"))

        var session = try unlockFixture(dir, identity: identity, store: store)
        let revision = session.snapshot().generation
        let trustVersion = session.manifest.state.trustList.listVersion
        session.lock()

        // Second unlock: no migration, no commit, nothing changed.
        session = try unlockFixture(dir, identity: identity, store: store)
        #expect(session.snapshot().generation == revision)
        #expect(session.manifest.state.trustList.listVersion == trustVersion)
        session.lock()
    }

    @Test func recoveryScanSpansBothFormats() throws {
        // Damage HEAD on a MIGRATED vault that still carries its v0
        // object in the CAS: recovery must pick the v1 manifest
        // (higher local revision), not resurrect the v0 inventory.
        let (dir, cleanup) = try scratchCopy()
        defer { cleanup() }
        let identity = try DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: dir.deletingLastPathComponent().appendingPathComponent("rollback.json"))
        var session = try unlockFixture(dir, identity: identity, store: store)
        let revision = session.snapshot().generation
        let fileCount = session.snapshot().files.count
        session.lock()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("HEAD"))
        session = try unlockFixture(dir, identity: identity, store: store)
        #expect(session.snapshot().generation == revision)
        #expect(session.snapshot().files.count == fileCount)
        #expect(session.manifest.state.entries.allSatisfy { $0.migratedFromV0 })
        session.lock()

        // HEAD repaired to v1.
        let repaired = try HeadFile.parse(
            [UInt8](try Data(contentsOf: dir.appendingPathComponent("HEAD"))))
        guard case .v1 = repaired else {
            Issue.record("recovery must repair HEAD as v1")
            return
        }
    }
}

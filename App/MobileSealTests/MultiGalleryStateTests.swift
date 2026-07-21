import CryptoKit
import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// CED-14 gate 3 (state half): registry discovery + identity,
/// duplicate/corrupt directories as error tiles, creation crash
/// points, the idempotent crash-injected single-gallery migration
/// (WS B.3), per-gallery lock preferences, and the typed label-store
/// failure matrix (WS B.2).
@MainActor
@Suite struct MultiGalleryStateTests {

    private func makeIdentity(_ container: AppContainer) throws -> DeviceIdentity {
        try TestDeviceKeyStore(
            url: container.deviceLocalDir.appendingPathComponent("test-device-key")
        ).loadOrCreateIdentity()
    }

    /// Creates a real gallery directly through VaultCore (no
    /// coordinator): the registry must key on the AUTHORITATIVE
    /// `gallery.meta` UUID, not the directory basename.
    @discardableResult
    private func createGallery(
        in container: AppContainer, password: String = "registry test pw"
    ) throws -> (id: UUID, directory: URL) {
        let dir = container.newGalleryDirectory()
        let pw = try SecureBytes(nfcNormalizedPassword: password)
        let vault = try SealedVault.create(
            at: dir, password: pw, kdfParams: TestSupport.fastParams,
            identity: try makeIdentity(container), deviceName: "state-test-device")
        return (vault.meta.galleryID, dir)
    }

    // MARK: - Registry discovery

    @Test func scanKeysOnMetaUUIDAndOrdersByCreatedDate() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let registry = GalleryRegistry(container: container)

        let a = try createGallery(in: container)
        let b = try createGallery(in: container)
        // Record b as OLDER than a: ordering must follow the sidecar
        // dates, not directory names.
        registry.recordCreated(id: a.id, at: Date())
        registry.recordCreated(id: b.id, at: Date(timeIntervalSinceNow: -3600))

        let snapshot = registry.scan()
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.records.map(\.id) == [b.id, a.id])
        #expect(Set(snapshot.records.map(\.directory.lastPathComponent))
            == Set([a.directory.lastPathComponent, b.directory.lastPathComponent]))
    }

    @Test func duplicateCopiedDirectorySurfacesAsErrorTilesNotDataLoss() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let registry = GalleryRegistry(container: container)

        let a = try createGallery(in: container)
        registry.recordCreated(id: a.id)
        // A copied gallery directory: same authoritative UUID twice.
        let copy = container.newGalleryDirectory()
        try FileManager.default.copyItem(at: a.directory, to: copy)

        let snapshot = registry.scan()
        // NEITHER site is openable (UUID-keyed device state would
        // cross-apply) — both surface as duplicate error tiles.
        #expect(!snapshot.records.contains { $0.id == a.id })
        let duplicates = snapshot.failures.filter {
            $0.reason == .duplicateGalleryID(a.id)
        }
        #expect(duplicates.count == 2)
    }

    @Test func unreadableMetaSurfacesAsErrorTile() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let registry = GalleryRegistry(container: container)

        let broken = container.newGalleryDirectory()
        try FileManager.default.createDirectory(
            at: broken, withIntermediateDirectories: true)
        try Data("not a gallery meta".utf8).write(
            to: broken.appendingPathComponent("gallery.meta"))

        let snapshot = registry.scan()
        #expect(snapshot.records.isEmpty)
        #expect(snapshot.failures.count == 1)
        if case .unreadableMeta = snapshot.failures[0].reason {
        } else {
            Issue.record("expected unreadableMeta, got \(snapshot.failures[0].reason)")
        }
    }

    /// Creation crash point (WS B.1): the gallery exists on disk but
    /// the sidecar write never happened — the scan still lists it
    /// (filesystem is authoritative) and the backfill self-heals a
    /// best-effort date.
    @Test func creationCrashBeforeSidecarRecordSelfHeals() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let registry = GalleryRegistry(container: container)

        let a = try createGallery(in: container)
        var snapshot = registry.scan()
        #expect(snapshot.records.map(\.id) == [a.id])
        #expect(snapshot.records[0].createdAt == nil)

        registry.backfillMissingDates(for: snapshot.records)
        snapshot = registry.scan()
        #expect(snapshot.records[0].createdAt != nil)
    }

    /// The ACTIVE (claimed) gallery's directory is never re-read
    /// (plan review B4): its cached record stands in — proved by
    /// scanning after the meta file is gone.
    @Test func activeGalleryIsNotReReadDuringScan() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let registry = GalleryRegistry(container: container)

        let a = try createGallery(in: container)
        let cached = GalleryRecord(id: a.id, directory: a.directory, createdAt: Date())
        // Replace the meta with garbage: a re-read would now fail.
        try Data("gone".utf8).write(to: a.directory.appendingPathComponent("gallery.meta"))

        let snapshot = registry.scan(activeRecord: cached)
        #expect(snapshot.records == [cached])
        #expect(snapshot.failures.isEmpty)
    }

    // MARK: - Single-gallery migration (WS B.3, crash-injected)

    private func plantLegacyState(
        _ container: AppContainer, defaults: UserDefaults
    ) throws {
        defaults.set("grace", forKey: LockPreferences.legacyBackgroundPolicyKey)
        defaults.set(TimeInterval(60), forKey: LockPreferences.legacyIdleTimeoutKey)
        let record = KDFCalibrator.Record(
            date: Date(), chosenOpslimit: 3, chosenMemlimitMiB: 512,
            fallbackReason: nil, thermalState: "nominal",
            availableMemoryMiB: nil, releaseBuild: false)
        try JSONEncoder().encode(record).write(to: container.legacyCalibrationURL)
    }

    private func assertMigrated(
        _ container: AppContainer, defaults: UserDefaults, galleryID: UUID
    ) throws {
        let prefs = LockPreferences.load(from: defaults, galleryID: galleryID)
        #expect(prefs.backgroundPolicy == .grace)
        #expect(prefs.idleTimeout == 60)
        #expect(defaults.object(forKey: LockPreferences.legacyBackgroundPolicyKey) == nil)
        #expect(defaults.object(forKey: LockPreferences.legacyIdleTimeoutKey) == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: container.calibrationURL(galleryID: galleryID).path))
        #expect(!FileManager.default.fileExists(atPath: container.legacyCalibrationURL.path))
        let data = try Data(contentsOf: container.calibrationURL(galleryID: galleryID))
        let record = try JSONDecoder().decode(KDFCalibrator.Record.self, from: data)
        #expect(record.chosenMemlimitMiB == 512)
    }

    @Test func migrationMovesLegacyStateToGalleryOneAndIsIdempotent() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let defaults = UserDefaults(suiteName: "migration-\(UUID().uuidString)")!
        let registry = GalleryRegistry(container: container)
        let a = try createGallery(in: container)
        try plantLegacyState(container, defaults: defaults)

        try registry.migrateIfNeeded(records: registry.scan().records, defaults: defaults)
        try assertMigrated(container, defaults: defaults, galleryID: a.id)
        // Sidecar date backfilled as part of migration.
        #expect(registry.scan().records[0].createdAt != nil)

        // Idempotent: a second run changes nothing and does not
        // overwrite per-gallery values with anything.
        var prefs = LockPreferences.load(from: defaults, galleryID: a.id)
        prefs.idleTimeout = 900
        prefs.save(to: defaults, galleryID: a.id)
        try registry.migrateIfNeeded(records: registry.scan().records, defaults: defaults)
        #expect(LockPreferences.load(from: defaults, galleryID: a.id).idleTimeout == 900)
    }

    @Test(arguments: [
        GalleryRegistry.MigrationFailpoint.afterCalibrationCopied,
        .afterCalibrationLegacyRemoved,
        .afterPrefsMigrated,
    ])
    func migrationConvergesAfterCrashAtEveryStep(
        _ failpoint: GalleryRegistry.MigrationFailpoint
    ) async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let defaults = UserDefaults(suiteName: "migration-crash-\(UUID().uuidString)")!
        let registry = GalleryRegistry(container: container)
        let a = try createGallery(in: container)
        try plantLegacyState(container, defaults: defaults)

        // Crash at the injected step…
        #expect(throws: GalleryRegistry.MigrationFailpoint.Injected.self) {
            try registry.migrateIfNeeded(
                records: registry.scan().records, defaults: defaults,
                failpoint: failpoint)
        }
        // …then the next launch's ordinary run converges fully.
        try registry.migrateIfNeeded(records: registry.scan().records, defaults: defaults)
        try assertMigrated(container, defaults: defaults, galleryID: a.id)
    }

    // MARK: - Per-gallery lock preferences (WS A.3)

    @Test func lockPreferencesAreIndependentPerGallery() async throws {
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        let a = UUID()
        let b = UUID()
        var prefsA = LockPreferences()
        prefsA.backgroundPolicy = .off
        prefsA.idleTimeout = 0
        prefsA.save(to: defaults, galleryID: a)

        #expect(LockPreferences.load(from: defaults, galleryID: a).backgroundPolicy == .off)
        // B keeps strict defaults — untouched by A's writes.
        let loadedB = LockPreferences.load(from: defaults, galleryID: b)
        #expect(loadedB.backgroundPolicy == .immediate)
        #expect(loadedB.idleTimeout == 300)
    }

    @Test func resetAllClearsLegacyAndPerGalleryKeys() async throws {
        let defaults = UserDefaults(suiteName: "reset-\(UUID().uuidString)")!
        let a = UUID()
        var prefs = LockPreferences()
        prefs.backgroundPolicy = .off
        prefs.save(to: defaults, galleryID: a)
        defaults.set("grace", forKey: LockPreferences.legacyBackgroundPolicyKey)

        LockPreferences.resetAll(in: defaults)
        #expect(LockPreferences.load(from: defaults, galleryID: a).backgroundPolicy == .immediate)
        #expect(defaults.object(forKey: LockPreferences.legacyBackgroundPolicyKey) == nil)
    }

    // MARK: - Label store failure matrix (WS B.2, plan review B8/B9)

    private func makeLabelStore(
        _ container: AppContainer, keyFile: String = "label-key"
    ) -> GalleryLabelStore {
        GalleryLabelStore(
            container: container,
            keyStore: FileLabelKeyStore(
                url: container.deviceLocalDir.appendingPathComponent(keyFile)))
    }

    @Test func labelRoundTripsNameAndCover() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let store = makeLabelStore(container)
        let id = UUID()

        let cover = try GalleryLabelStore.makeCoverJPEG(
            fromDecryptedOriginal: Data(
                contentsOf: TestSupport.fixtureURL("fixture-0000.jpg")))
        try store.setLabel(GalleryLabel(name: "Family", coverJPEG: cover), for: id)

        guard case .labeled(let label) = store.label(for: id) else {
            Issue.record("expected labeled outcome")
            return
        }
        #expect(label.name == "Family")
        #expect(label.coverJPEG == cover)
        // The record on disk is ciphertext: neither the name nor the
        // cover bytes appear in it.
        let sealed = try Data(contentsOf: container.labelURL(galleryID: id))
        #expect(sealed.range(of: Data("Family".utf8)) == nil)
        #expect(sealed.range(of: cover.subdata(in: cover.count / 2..<cover.count / 2 + 32)) == nil)
    }

    /// A record copied between galleries fails the gallery-UUID AAD
    /// binding: typed unreadable → generic tile, never a cross-applied
    /// label (plan review B8).
    @Test func swappedLabelRecordFailsTyped() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let store = makeLabelStore(container)
        let a = UUID()
        let b = UUID()
        try store.setLabel(GalleryLabel(name: "Alpha", coverJPEG: nil), for: a)
        try FileManager.default.copyItem(
            at: container.labelURL(galleryID: a), to: container.labelURL(galleryID: b))

        #expect(store.label(for: b) == .unreadable)
        // The original still reads.
        #expect(store.label(for: a) == .labeled(GalleryLabel(name: "Alpha", coverJPEG: nil)))
    }

    @Test func corruptLabelRecordFailsTyped() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let store = makeLabelStore(container)
        let id = UUID()
        try store.setLabel(GalleryLabel(name: "Alpha", coverJPEG: nil), for: id)
        var bytes = try Data(contentsOf: container.labelURL(galleryID: id))
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: container.labelURL(galleryID: id))

        #expect(store.label(for: id) == .unreadable)
    }

    /// The defined restore outcome (plan review B8): ciphertext rode
    /// backup, the `ThisDeviceOnly` key did not — typed keyUnavailable
    /// → generic tiles; recovery = relabel.
    @Test func missingKeyAfterRestoreIsTypedKeyUnavailable() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let id = UUID()
        try makeLabelStore(container, keyFile: "old-device-key")
            .setLabel(GalleryLabel(name: "Alpha", coverJPEG: nil), for: id)

        // "Restored" device: label ciphertext present, key absent.
        let restored = makeLabelStore(container, keyFile: "new-device-key")
        #expect(restored.label(for: id) == .keyUnavailable)
    }

    @Test func emptyLabelRemovesRecord() async throws {
        let container = try TestSupport.makeContainer()
        defer { TestSupport.removeContainer(container) }
        let store = makeLabelStore(container)
        let id = UUID()
        try store.setLabel(GalleryLabel(name: "Alpha", coverJPEG: nil), for: id)
        #expect(FileManager.default.fileExists(atPath: container.labelURL(galleryID: id).path))

        try store.setLabel(GalleryLabel(name: nil, coverJPEG: nil), for: id)
        #expect(!FileManager.default.fileExists(atPath: container.labelURL(galleryID: id).path))
        #expect(store.label(for: id) == .unlabeled)
    }
}

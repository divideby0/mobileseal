import Foundation
import OSLog
import VaultCore

/// The app-container contract (GOAL WS A.3, Codex B8).
///
/// Layout under the app's Application Support directory:
///
///     Application Support/
///       Vault/                      ← "vault root": ciphertext only,
///         galleries/{uuid}/         ← one VaultCore gallery directory
///       Staging/                    ← plaintext picker material, transient
///
/// Contract:
///  - Vault root files carry iOS Data Protection `.completeUnlessOpen`
///    (writable during background import completion) and PARTICIPATE
///    in iCloud/device backup — ciphertext is safe to back up and is
///    the only pre-sync path that survives device migration. Gate 4
///    asserts nothing under the vault root is `isExcludedFromBackup`.
///  - Staging holds the only plaintext ever written to disk by the
///    app: provider copy-ins live there between "staged" and
///    "imported", are removed at import end (success, failure, or
///    cancellation), and the WHOLE directory is wiped on every launch
///    so a crash mid-import cannot strand plaintext (gate 4's crash
///    path). Staging is excluded from backup.
struct AppContainer: Sendable {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "container")

    let vaultRoot: URL
    let galleriesDir: URL
    let stagingDir: URL
    /// EXPORT staging (CED-15 WS A.1, Codex B3): the one deliberate
    /// custody exit stages decrypted originals here before the share
    /// sheet hands them to a chosen activity. A SIBLING of `Staging/`,
    /// deliberately NOT under it: import's wipe-all (`wipeStaging()`,
    /// called at every import end) must never race a live export
    /// handoff. Same custody contract as Staging — `.completeUnlessOpen`,
    /// backup-excluded, swept on every launch (crash path) and by the
    /// export lock participant.
    let exportStagingDir: URL
    /// DEVICE-LOCAL state (CED-13 WS B.7): the rollback high-water
    /// marks and the soft-delete ledger. Lives OUTSIDE the vault root
    /// and is EXCLUDED from backup — it describes THIS device's
    /// observations (beside the Keychain identity, which is
    /// `ThisDeviceOnly` for the same reason): it must neither roll
    /// back with a restored vault nor follow the vault to a new
    /// device.
    let deviceLocalDir: URL
    /// Device-local gallery LABELS (CED-14 WS B.2): AEAD ciphertext
    /// under the Keychain label key. Deliberately NOT backup-excluded
    /// (unlike DeviceLocal): the ciphertext MAY ride backup — the key
    /// is `ThisDeviceOnly`, so the DEFINED restore outcome is graceful
    /// loss (labels reset to generic tiles; recovery = relabel).
    let labelsDir: URL

    /// Standard container in Application Support.
    static func standard() throws -> AppContainer {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try AppContainer(base: base)
    }

    /// Seam for tests: any base directory works (unit tests use temp
    /// dirs so parallel tests never share state).
    init(base: URL) throws {
        vaultRoot = base.appendingPathComponent("Vault", isDirectory: true)
        galleriesDir = vaultRoot.appendingPathComponent("galleries", isDirectory: true)
        stagingDir = base.appendingPathComponent("Staging", isDirectory: true)
        exportStagingDir = base.appendingPathComponent("StagingExport", isDirectory: true)
        deviceLocalDir = base.appendingPathComponent("DeviceLocal", isDirectory: true)
        labelsDir = base.appendingPathComponent("Labels", isDirectory: true)
        try prepare()
    }

    private func prepare() throws {
        let fm = FileManager.default
        for dir in [vaultRoot, galleriesDir, stagingDir, exportStagingDir, deviceLocalDir, labelsDir]
        {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        Self.applyProtection(.completeUnlessOpen, to: vaultRoot)
        Self.applyProtection(.completeUnlessOpen, to: stagingDir)
        Self.applyProtection(.completeUnlessOpen, to: exportStagingDir)
        Self.applyProtection(.completeUnlessOpen, to: deviceLocalDir)
        Self.applyProtection(.completeUnlessOpen, to: labelsDir)
        // Vault root participates in backup (grill Q7): assert the
        // exclusion flag is NOT set rather than setting anything.
        // Staging is transient plaintext workspace — never back it up.
        // DeviceLocal is per-device observation state — never back it
        // up either (CED-13 WS B.7: a backed-up high-water mark would
        // roll back with the vault it is meant to check).
        // A failure here is a custody-contract breach and must be
        // LOUD, not swallowed (wave-001 coderabbit #3).
        for dir in [stagingDir, exportStagingDir, deviceLocalDir] {
            var target = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try target.setResourceValues(values)
            } catch {
                Self.log.fault(
                    "failed to exclude \(dir.lastPathComponent, privacy: .public) from backup: \(String(describing: error), privacy: .public)"
                )
                assertionFailure("backup exclusion failed for \(dir.path): \(error)")
            }
        }
    }

    /// The rollback high-water store location (CED-13 WS B.7).
    var rollbackStateURL: URL {
        deviceLocalDir.appendingPathComponent("rollback-state.json")
    }

    /// The device-local soft-delete ledger for one gallery (CED-13 WS
    /// C.2 — delete-for-myself is device-local this leg).
    func recentlyDeletedURL(galleryID: UUID) -> URL {
        deviceLocalDir.appendingPathComponent(
            "recently-deleted-\(galleryID.uuidString.lowercased()).json")
    }

    // MARK: - CED-14 per-gallery state locations (WS A.3 ownership table)

    /// The gallery registry's created-date sidecar (CED-14 WS B.1):
    /// gallery UUID → created-at ONLY. Never authoritative for
    /// existence (the filesystem scan is), never names or covers
    /// (labels are device-local). Lives in the vault root, so the
    /// dates ride ciphertext backup — they are not secret.
    var registryURL: URL {
        vaultRoot.appendingPathComponent("registry.json")
    }

    /// Per-gallery KDF calibration record (CED-14 WS A.3, Codex B5:
    /// the single `calibration.json` becomes per-gallery records).
    func calibrationURL(galleryID: UUID) -> URL {
        vaultRoot.appendingPathComponent(
            "calibration-\(galleryID.uuidString.lowercased()).json")
    }

    /// The pre-CED-14 single global calibration record — migration
    /// source only (becomes gallery #1's record).
    var legacyCalibrationURL: URL {
        vaultRoot.appendingPathComponent("calibration.json")
    }

    /// One gallery's sealed device-local label record (CED-14 WS B.2).
    func labelURL(galleryID: UUID) -> URL {
        labelsDir.appendingPathComponent(
            "label-\(galleryID.uuidString.lowercased()).sealed")
    }

    /// EVERY directory under galleries/, sorted by basename (CED-14
    /// WS A.1 — the registry's discovery scan; identity comes from
    /// the meta UUID, the path is location only). Deliberately does
    /// NOT pre-filter on `gallery.meta` (wave-001 codex #1): a
    /// gallery whose meta went missing must surface as an ERROR TILE,
    /// not silently vanish into a "no galleries" setup route. Throws
    /// on an enumeration failure so the registry can represent it
    /// explicitly instead of an indistinguishable empty scan.
    func galleryDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: galleriesDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Directory-level Data Protection: files created inside inherit
    /// the class. Best-effort on simulator (attribute accepted but not
    /// enforced) and a no-op on non-iOS platforms — the residual gap
    /// is a documented device-only check (Codex A7).
    static func applyProtection(_ type: FileProtectionType, to url: URL) {
        #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: type], ofItemAtPath: url.path)
        #endif
    }

    // MARK: - Gallery discovery

    /// First-gallery helper retained for UI-test seeding
    /// (`UITestSupport.seedV0VaultIfRequested`) and coordinator-level
    /// test fixtures. NOT the production discovery path since CED-14 —
    /// that is `galleryDirectories()` + `GalleryRegistry.scan()`
    /// (wave-001 claude-code #4).
    func existingGalleryDirectory() -> URL? {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: galleriesDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return nil }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { fm.fileExists(atPath: $0.appendingPathComponent("gallery.meta").path) }
    }

    /// Mints the directory for a new gallery (name = fresh UUID; the
    /// galleries/{id} container convention from CONTEXT.md).
    func newGalleryDirectory() -> URL {
        galleriesDir.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    // MARK: - Staging lifecycle

    /// Wipes everything under Staging/. Called on every launch and at
    /// import end — the crash-path half of the custody claim. A
    /// removal failure strands plaintext, so it is surfaced loudly
    /// rather than discarded (wave-001 coderabbit #4).
    func wipeStaging() {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: stagingDir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            do {
                try fm.removeItem(at: entry)
            } catch {
                Self.log.fault(
                    "failed to wipe staged plaintext at \(entry.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                assertionFailure("staging wipe failed at \(entry.path): \(error)")
            }
        }
    }

    /// A fresh per-batch staging subdirectory.
    func makeBatchStagingDirectory() throws -> URL {
        let dir = stagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyProtection(.completeUnlessOpen, to: dir)
        return dir
    }

    // MARK: - Export staging lifecycle (CED-15 WS A)

    /// Wipes everything under StagingExport/ — the export half of the
    /// crash-path custody claim (swept on launch, on lock via the
    /// export lock participant, and at share completion). Same
    /// loud-failure policy as `wipeStaging()`.
    func wipeExportStaging() {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: exportStagingDir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            do {
                try fm.removeItem(at: entry)
            } catch {
                Self.log.fault(
                    "failed to wipe export staging at \(entry.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                assertionFailure("export staging wipe failed at \(entry.path): \(error)")
            }
        }
    }

    /// A fresh per-batch export staging subdirectory.
    func makeExportBatchDirectory() throws -> URL {
        let dir = exportStagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyProtection(.completeUnlessOpen, to: dir)
        return dir
    }
}

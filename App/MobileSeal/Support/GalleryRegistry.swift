import Foundation
import OSLog
import VaultCore

/// One discovered gallery as the switcher list presents it (CED-14 WS
/// B.1). Identity is the AUTHORITATIVE `gallery.meta` UUID (plan
/// review Q17/B7); the directory path is location only — a moved or
/// restored directory keeps its device-local metadata because every
/// per-gallery key (labels, lock prefs, calibration, Recently
/// Deleted) is keyed by this UUID.
struct GalleryRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let directory: URL
    /// Registry-recorded creation date (sealed-plane honesty, plan
    /// review A11: `gallery.meta` carries no trustworthy creation
    /// date — this is APP metadata, backfilled best-effort from file
    /// metadata for pre-registry galleries; nil = unknown).
    let createdAt: Date?
}

/// A galleries/ directory the list cannot honestly represent: it
/// surfaces as an ERROR TILE, never silent data loss (plan review B7).
struct GalleryDiscoveryFailure: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// Two directories parse to the same gallery UUID (a copied
        /// directory): NEITHER is listed as openable — per-gallery
        /// state (labels, prefs, soft-delete ledgers) is UUID-keyed
        /// and would silently cross-apply.
        case duplicateGalleryID(UUID)
        /// `gallery.meta` missing, unreadable, or structurally
        /// invalid — while gallery CONTENT is present (wave-001 codex
        /// #1: a lost meta must never make a gallery silently vanish
        /// into the "no galleries" setup route).
        case unreadableMeta(String)
        /// The galleries root itself could not be enumerated: shown
        /// instead of an indistinguishable empty scan.
        case scanFailed(String)
    }

    var id: String { directory.lastPathComponent }
    let directory: URL
    let reason: Reason
}

/// One registry scan's result.
struct GallerySnapshot: Equatable, Sendable {
    var records: [GalleryRecord] = []
    var failures: [GalleryDiscoveryFailure] = []
}

/// Discovery + created-date sidecar + the single-gallery migration
/// (CED-14 WS A.1/B.3). The FILESYSTEM is authoritative for existence
/// — the sidecar (`registry.json`) enriches records with created
/// dates and is self-healing: a gallery missing from it (creation
/// crashed between `SealedVault.create` and the sidecar write) is
/// re-recorded on the next scan with a best-effort date.
struct GalleryRegistry: Sendable {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "registry")

    let container: AppContainer

    /// Sidecar shape: gallery UUID (lowercased) → created-at. Dates
    /// only — names and covers are device-local label material and
    /// never live here (the sidecar rides ciphertext backup).
    private struct Sidecar: Codable {
        var createdAt: [String: Date] = [:]
    }

    // MARK: - Scan

    /// Discovers every gallery under galleries/. `activeRecord` is the
    /// currently claimed gallery, if any: its directory is NEVER
    /// re-read while claimed (plan review B4) — the cached record
    /// stands in, and still participates in duplicate detection.
    func scan(activeRecord: GalleryRecord? = nil) -> GallerySnapshot {
        var byID: [UUID: [(URL, Date?)]] = [:]
        var failures: [GalleryDiscoveryFailure] = []
        let sidecar = loadSidecar()

        let directories: [URL]
        do {
            directories = try container.galleryDirectories()
        } catch {
            // An enumeration failure is REPRESENTED, never collapsed
            // to an empty scan that would route to setup (wave-001
            // codex #1).
            return GallerySnapshot(
                records: [],
                failures: [
                    GalleryDiscoveryFailure(
                        directory: container.galleriesDir,
                        reason: .scanFailed(String(describing: error)))
                ])
        }
        for directory in directories {
            if let active = activeRecord,
                directory.standardizedFileURL.path == active.directory.standardizedFileURL.path
            {
                byID[active.id, default: []].append((active.directory, active.createdAt))
                continue
            }
            do {
                let meta = try SealedVault.readStructuralMeta(directory: directory)
                let created = sidecar.createdAt[meta.galleryID.uuidString.lowercased()]
                byID[meta.galleryID, default: []].append((directory, created))
            } catch {
                // A husk from a crashed creation (no meta AND nothing
                // that could hold data) is debris, not damage — the
                // error tile is reserved for directories with content
                // to lose.
                if Self.isCreationDebris(directory) {
                    Self.log.info(
                        "ignoring empty creation debris at \(directory.lastPathComponent, privacy: .public)"
                    )
                    continue
                }
                failures.append(
                    GalleryDiscoveryFailure(
                        directory: directory,
                        reason: .unreadableMeta(String(describing: error))))
            }
        }

        var records: [GalleryRecord] = []
        for (id, sites) in byID {
            if sites.count == 1 {
                records.append(
                    GalleryRecord(id: id, directory: sites[0].0, createdAt: sites[0].1))
            } else {
                for (directory, _) in sites {
                    failures.append(
                        GalleryDiscoveryFailure(
                            directory: directory, reason: .duplicateGalleryID(id)))
                }
            }
        }
        // Stable order: registry-recorded creation date, unknown-date
        // records last, directory basename as the tiebreaker.
        records.sort {
            switch ($0.createdAt, $1.createdAt) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                return $0.directory.lastPathComponent < $1.directory.lastPathComponent
            }
        }
        failures.sort { $0.directory.lastPathComponent < $1.directory.lastPathComponent }
        return GallerySnapshot(records: records, failures: failures)
    }

    /// True when `directory` is a crashed creation's empty husk: no
    /// `gallery.meta`, no HEAD, and no objects under chunks/ or
    /// manifest/ — provably nothing to lose. Anything else without a
    /// parsable meta is an error tile.
    private static func isCreationDebris(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.appendingPathComponent("gallery.meta").path)
        else { return false }
        guard !fm.fileExists(atPath: directory.appendingPathComponent("HEAD").path) else {
            return false
        }
        for sub in ["chunks", "manifest"] {
            let contents =
                (try? fm.contentsOfDirectory(
                    atPath: directory.appendingPathComponent(sub).path)) ?? []
            if contents.contains(where: { $0 != ".DS_Store" }) { return false }
        }
        return true
    }

    // MARK: - Sidecar

    private func loadSidecar() -> Sidecar {
        guard let data = try? Data(contentsOf: container.registryURL) else { return Sidecar() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sidecar = try? decoder.decode(Sidecar.self, from: data) else {
            // Corrupt sidecar: dates degrade to unknown, discovery
            // itself is unaffected (filesystem is authoritative). The
            // next recordCreated rewrites it.
            Self.log.error("registry sidecar unreadable — created dates degrade to unknown")
            return Sidecar()
        }
        return sidecar
    }

    private func saveSidecar(_ sidecar: Sidecar) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sidecar) else { return }
        do {
            try data.write(to: container.registryURL, options: [.atomic])
        } catch {
            // Non-fatal: dates degrade to unknown; the scan self-heals
            // via the backfill pass.
            Self.log.error(
                "registry sidecar write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Records a fresh gallery's creation date. Crash BEFORE this call
    /// is a covered creation crash point: the next scan lists the
    /// gallery (filesystem truth) and `backfillMissingDates` restores
    /// a best-effort date.
    func recordCreated(id: UUID, at date: Date = Date()) {
        var sidecar = loadSidecar()
        sidecar.createdAt[id.uuidString.lowercased()] = date
        saveSidecar(sidecar)
    }

    /// Self-heal: every discovered gallery absent from the sidecar
    /// gets a best-effort date (the meta file's creation timestamp —
    /// UNSTABLE across copies/restores, hence best-effort only; plan
    /// review A11). Idempotent: present entries are never touched.
    func backfillMissingDates(for records: [GalleryRecord]) {
        var sidecar = loadSidecar()
        var changed = false
        for record in records
        where sidecar.createdAt[record.id.uuidString.lowercased()] == nil {
            let metaURL = record.directory.appendingPathComponent("gallery.meta")
            let fileDate =
                (try? FileManager.default.attributesOfItem(atPath: metaURL.path))?[
                    .creationDate] as? Date
            sidecar.createdAt[record.id.uuidString.lowercased()] = fileDate ?? Date()
            changed = true
        }
        if changed { saveSidecar(sidecar) }
    }

    // MARK: - Single-gallery migration (WS B.3)

    /// Crash-injection seam for the migration's unit gates: each step
    /// boundary calls `check`, which throws in tests to simulate a
    /// crash at that point. Production passes `.none`.
    enum MigrationFailpoint: Equatable, Sendable {
        case none
        case afterCalibrationCopied
        case afterCalibrationLegacyRemoved
        case afterPrefsMigrated

        struct Injected: Error {}

        func check(_ step: MigrationFailpoint) throws {
            if case .none = self { return }
            if self == step { throw Injected() }
        }
    }

    /// The pre-CED-14 single gallery becomes registry entry #1 with
    /// its current settings (WS B.3, plan review B7): the global lock
    /// preferences move to its per-gallery keys, the global
    /// `calibration.json` becomes its per-gallery record, and the
    /// sidecar gains its created date. IDEMPOTENT at every crash
    /// point — each step converges on re-run and never overwrites a
    /// value the target already has. Runs on every bootstrap; a
    /// fully-migrated container is a fast no-op.
    func migrateIfNeeded(
        records: [GalleryRecord], defaults: UserDefaults,
        failpoint: MigrationFailpoint = .none
    ) throws {
        // Legacy state predates multiple galleries, so it can only
        // belong to the FIRST gallery (there was exactly one when it
        // was written). Sort order makes "first" deterministic even in
        // the degenerate multi-gallery-with-legacy-state case.
        guard let first = records.first else { return }
        let fm = FileManager.default

        // Calibration: validate → atomic write → read-back verify →
        // remove source (wave-001 codex #2: an existing target is
        // only trusted if it DECODES — a partial file from a crashed
        // copy is replaced from the still-intact legacy record, never
        // the other way around; the source is removed only after the
        // destination provably holds a valid record).
        let legacy = container.legacyCalibrationURL
        let target = container.calibrationURL(galleryID: first.id)
        func decodesAsRecord(_ url: URL) -> Bool {
            guard let data = try? Data(contentsOf: url) else { return false }
            return (try? JSONDecoder().decode(KDFCalibrator.Record.self, from: data)) != nil
        }
        if fm.fileExists(atPath: legacy.path) {
            if decodesAsRecord(legacy) {
                if !decodesAsRecord(target) {
                    let data = try Data(contentsOf: legacy)
                    try data.write(to: target, options: [.atomic])
                }
                try failpoint.check(.afterCalibrationCopied)
                if decodesAsRecord(target) {
                    try fm.removeItem(at: legacy)
                }
            } else {
                // The legacy record itself is unreadable: preserve it
                // (never delete the only copy), report, move on — the
                // record is a display artifact, not custody state.
                Self.log.error("legacy calibration record undecodable — left in place")
            }
        }
        try failpoint.check(.afterCalibrationLegacyRemoved)

        LockPreferences.migrateLegacy(to: first.id, defaults: defaults)
        try failpoint.check(.afterPrefsMigrated)

        backfillMissingDates(for: records)
    }
}

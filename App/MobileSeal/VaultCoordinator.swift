import Foundation
import OSLog
import VaultCore

extension Optional where Wrapped: ~Copyable {
    /// Moves the wrapped value out, leaving nil — the one legal way to
    /// consume a move-only value held in reference-type storage.
    mutating func take() -> Wrapped? {
        let taken = consume self
        self = nil
        return taken
    }
}

/// Coordinator lifecycle phase (GOAL WS A.1) — the explicit transition
/// set from the Codex B3 spike: create, unlock, importing, locking,
/// locked, unlock failure, teardown. (Scene `.inactive` is deliberately
/// NOT a phase: redaction ≠ lock — the shield is view state owned by
/// the store, and transient inactivity never locks.)
enum VaultPhase: Equatable, Sendable {
    case starting
    /// No gallery exists on disk yet.
    case needsSetup
    /// Calibration + `SealedVault.create` in flight.
    case creating
    case locked
    /// KDF in flight.
    case unlocking
    case unlocked(importing: Bool)
    /// Consuming `lock()` in flight (drains up to 500 ms).
    case locking
    /// Gallery-level integrity failure (GOAL WS D.5) — distinct from
    /// per-item damage, which rides `MediaItem.damaged`.
    case galleryError(GalleryFailure)

    var isUnlocked: Bool {
        if case .unlocked = self { return true } else { return false }
    }
}

/// Unlock-attempt failures as the UI must present them.
enum UnlockFailure: Equatable, Sendable {
    /// `dekUnwrapFailed`: wrong password and keyring tamper are
    /// cryptographically indistinguishable — the copy must say so.
    case wrongPasswordOrDamagedKeyring
    /// VaultCore's local backoff; retry after the given seconds.
    case rateLimited(retryAfterSeconds: Double)
    /// `galleryAlreadyOpen`: single-scene policy says this surfaces as
    /// "vault is open elsewhere", never a crash.
    case vaultOpenElsewhere
    /// Rollback detector fired (CED-13 WS B.7): a known device
    /// presented an older manifest than this device has seen — the
    /// signature of restoring the vault from an older backup. The UI
    /// offers the acceptance flow (re-unlock with `acceptRollback`),
    /// which re-baselines and RECORDS the acceptance.
    case restoredFromOlderBackup
    case other(String)
}

/// One soft-deleted aggregate as the Recently Deleted screen shows it
/// (CED-13 WS C.2): the item (thumbnail still renderable — its entries
/// are untouched until purge) plus its expiry clock.
struct RecentlyDeletedItem: Equatable, Sendable, Identifiable {
    let item: MediaItem
    let deletedAt: Date
    let expiresAt: Date
    var id: FileID { item.id }

    var daysLeft: Int {
        max(0, Int(ceil(expiresAt.timeIntervalSinceNow / 86400)))
    }
}

enum GalleryFailure: Equatable, Sendable {
    /// `noValidInventory` — no readable index; damage.
    case noValidInventory
    /// `authenticationFailed(.inventory)` — deliberate-tamper signal.
    case inventoryTampered
    case other(String)
}

/// Index health surfaced alongside items (Codex B2 recovery rule:
/// orphans ignored-and-reported, missing thumbnails regenerate).
struct IndexReport: Equatable, Sendable {
    var orphanThumbnails: Int = 0
    var missingThumbnails: Int = 0
    var undecodableEntries: Int = 0
}

/// The coordinator's outbound edge: a MainActor sink the UI store
/// adopts. Everything crossing is Sendable value state — never the
/// session, never secure buffers.
@MainActor
protocol VaultUISink: AnyObject, Sendable {
    func phaseChanged(_ phase: VaultPhase)
    func unlockFailed(_ failure: UnlockFailure)
    func itemsChanged(_ items: [MediaItem], report: IndexReport)
    /// Soft-deleted aggregates for the Recently Deleted screen
    /// (CED-13 WS C.2); emptied on lock like every plaintext-adjacent
    /// list.
    func recentlyDeletedChanged(_ items: [RecentlyDeletedItem])
    /// Fresh reader per committed generation (Codex B4); nil on lock.
    func readerChanged(_ reader: ChunkReader?)
    /// Fresh STREAMING reader per committed generation (CED-12 WS A);
    /// nil on lock, and nil while no playback cache is attached.
    func streamingReaderChanged(_ reader: StreamingReader?)
    func importProgressed(_ progress: ImportProgress?)
    func importFinished(_ summary: ImportSummary)
}

/// A participant in the coordinator's ONE lock path (CED-12 WS C.3):
/// `prepareForLock()` runs to completion BEFORE the custodian drain —
/// the playback controller uses it to fail loader requests, release
/// players, and zeroize its cache, in that order.
protocol VaultLockParticipant: Sendable {
    func prepareForLock() async
}

/// SOLE owner of the move-only `UnlockSession` and its `Gallery` /
/// reader / snapshot-task children (GOAL WS A.1, Codex B3). An actor:
/// every transition serializes here, off the main actor — so the
/// consuming `lock()` (which may block up to 500 ms draining readers)
/// never stalls the UI. The compile-fail harness's law holds
/// structurally: the session lives in actor storage and is moved out
/// with `Optional.take()` only inside actor-isolated methods; no task
/// closure ever captures it.
actor VaultCoordinator {
    /// Calibration seam: unit tests inject fast KDF params instead of
    /// paying real multi-second Argon2id measurement; UI-test mode
    /// uses the format floor so the scripted e2e stays quick.
    typealias CalibrationRunner = @Sendable (URL) -> (KDFParams, KDFCalibrator.Record)

    private let container: AppContainer
    private let calibration: CalibrationRunner
    /// Device identity custody (CED-13 WS A.1): Keychain-backed in
    /// production; injectable for app-hosted tests.
    private let deviceKeyStore: any DeviceKeyStore
    /// Human-readable name recorded in trust-list registrations.
    private let deviceName: String
    /// ONE rollback-state store instance for the coordinator's whole
    /// life (CED-14 WS A.3, plan review B6): the file store's internal
    /// per-gallery keying is correct, but a second instance over the
    /// same file would race unsynchronized read-modify-writes and
    /// could lose another gallery's observations — the CED-13
    /// fail-closed detector's ground truth. Never construct another.
    private let rollbackStore: any RollbackStateStore
    private weak var sink: (any VaultUISink)?

    private var session: UnlockSession?
    /// Mirrors whether `session` holds a value — pattern-matching a
    /// noncopyable Optional in reference storage is a consume, so the
    /// debug probe tracks liveness separately.
    private var sessionLive = false
    private var gallery: Gallery?
    private var galleryDirectory: URL?
    /// Sealed-plane chunk provider for the unlocked vault (CED-12 WS
    /// A.1); dropped on lock.
    private var chunkProvider: LocalChunkStore?
    /// Playback custody attachment (CED-12 WS C.3): the cache that
    /// streaming readers decrypt into, plus the lock participant
    /// swept before the custodian drain.
    private var playbackCache: ResidentChunkCache?
    private var lockParticipants: [any VaultLockParticipant] = []
    private var index = MediaIndex()
    private var latestSnapshot: InventorySnapshot?
    private var snapshotTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    /// Export custody owner (CED-15 WS A.2); registered like playback.
    private var exportController: ExportController?
    private(set) var phase: VaultPhase = .starting
    /// The unlocked gallery's soft-delete ledger (device-local,
    /// CED-13 WS C.2); nil while locked.
    private var recentlyDeletedStore: RecentlyDeletedStore?

    init(
        container: AppContainer, calibration: CalibrationRunner? = nil,
        deviceKeyStore: (any DeviceKeyStore)? = nil,
        deviceName: String? = nil,
        rollbackStore: (any RollbackStateStore)? = nil
    ) {
        self.container = container
        self.deviceKeyStore = deviceKeyStore ?? KeychainDeviceKeyStore()
        self.deviceName = deviceName ?? "This Device"
        self.rollbackStore = rollbackStore ?? FileRollbackStateStore(
            fileURL: container.rollbackStateURL)
        if let calibration {
            self.calibration = calibration
        } else if UITestSupport.isUITestMode {
            self.calibration = { _ in
                var record = KDFCalibrator.Record(
                    date: Date(), chosenOpslimit: 1, chosenMemlimitMiB: 16,
                    fallbackReason: "uitest fast params", thermalState: "n/a",
                    availableMemoryMiB: nil, releaseBuild: KDFCalibrator.isReleaseBuild)
                record.medians = [:]
                return (KDFParams(opslimit: 1, memlimit: 16 << 20), record)
            }
        } else {
            self.calibration = { KDFCalibrator.calibrate(scratchDir: $0) }
        }
    }

    func attach(sink: any VaultUISink) async {
        self.sink = sink
        await publishPhase()
    }

    /// Registers playback custody (CED-12 WS C.3): the controller's
    /// cache receives every streaming reader's decrypts, and its
    /// `prepareForLock` runs inside this coordinator's one lock path,
    /// before the custodian drain.
    func attachPlayback(
        cache: ResidentChunkCache, participant: any VaultLockParticipant
    ) {
        playbackCache = cache
        lockParticipants.append(participant)
    }

    /// Registers an additional participant in the ONE lock path
    /// (CED-14 WS A.2, plan review B2): the thumbnail pipeline rides
    /// here so that EVERY teardown — user lock, scene lock, idle
    /// backstop, gallery switch — purges decoded thumbnails before
    /// the custodian drain, structurally (nothing can call a "raw"
    /// coordinator lock that skips it).
    func attachLockParticipant(_ participant: any VaultLockParticipant) {
        lockParticipants.append(participant)
    }

    /// Registers export custody (CED-15 WS A.2, Codex B2): the
    /// controller owns StagingExport/ and rides the one lock path like
    /// playback — in-flight decrypt/writes cancel and the root sweeps
    /// before the custodian drain.
    func attachExport(controller: ExportController) {
        exportController = controller
        lockParticipants.append(controller)
    }

    // MARK: - Startup + selection (CED-14 WS A.2)

    /// Launch: wipe staging (crash-path custody — gate 4). Gallery
    /// DISCOVERY no longer lives here — the switchboard owns the
    /// registry scan and selection (plan review B1). IDEMPOTENT — only
    /// the `.starting` phase may route: SwiftUI re-runs the root
    /// `.task` when a full-screen UIKit presentation detaches and
    /// re-attaches the hosting view (CED-12 pager gate found this
    /// live).
    func start() async {
        guard phase == .starting else { return }
        container.wipeStaging()
        // Export half of the crash-path claim (CED-15 gate 2): a crash
        // mid-share strands decrypted originals in StagingExport/.
        container.wipeExportStaging()
        phase = .needsSetup
        await publishPhase()
    }

    /// Targets one gallery (switchboard-only entry): the coordinator
    /// becomes that gallery's locked session machine. Legal only while
    /// no session is live — the switchboard serializes teardown first.
    func select(directory: URL) async {
        switch phase {
        case .starting, .needsSetup, .locked, .galleryError:
            galleryDirectory = directory
            phase = .locked
            await publishPhase()
        default:
            assertionFailure("select while a session may be live: \(phase)")
        }
    }

    /// Clears the target (switchboard-only entry, same legality rule).
    func deselect() async {
        switch phase {
        case .starting, .needsSetup, .locked, .galleryError:
            galleryDirectory = nil
            phase = .needsSetup
            await publishPhase()
        default:
            assertionFailure("deselect while a session may be live: \(phase)")
        }
    }

    // MARK: - Create (calibrate-at-creation, GOAL WS D.4; per-gallery
    // KDF calibration per CED-14 WS A.1 — the CED-11 calibrator runs
    // for EVERY new gallery, and its record persists per gallery ID)

    /// Creates a gallery and adopts it unlocked. Returns the new
    /// gallery's authoritative `gallery.meta` UUID (nil on failure) so
    /// the switchboard can record creation + apply an optional label.
    @discardableResult
    func createGallery(password: String) async -> UUID? {
        guard phase == .needsSetup else { return nil }
        phase = .creating
        await publishPhase()

        let scratch = container.stagingDir
            .appendingPathComponent("calibration-\(UUID().uuidString)", isDirectory: true)
        let (params, record) = calibration(scratch)

        do {
            let dir = container.newGalleryDirectory()
            let pw = try SecureBytes(nfcNormalizedPassword: password)
            let identity = try deviceKeyStore.loadOrCreateIdentity()
            let vault = try SealedVault.create(
                at: dir, password: pw, kdfParams: params,
                identity: identity, deviceName: deviceName)
            persistCalibrationRecord(record, galleryID: vault.meta.galleryID)
            galleryDirectory = dir
            await adoptUnlocked(vault: vault, password: password)
            return vault.meta.galleryID
        } catch {
            phase = .needsSetup
            await publishPhase()
            await notifyUnlockFailure(mapUnlockError(error))
            return nil
        }
    }

    // MARK: - Unlock

    /// `acceptRollback` is the user-visible "restored from an older
    /// backup?" acceptance (CED-13 WS B.7): set only after the UI
    /// surfaced `.restoredFromOlderBackup` and the user chose to
    /// continue — it re-baselines the high-water mark and RECORDS the
    /// acceptance in the device-local store.
    func unlock(password: String, acceptRollback: Bool = false) async {
        guard phase == .locked else { return }
        guard let dir = galleryDirectory else {
            phase = .needsSetup
            await publishPhase()
            return
        }
        phase = .unlocking
        await publishPhase()
        do {
            let vault = try SealedVault(directory: dir)
            await adoptUnlocked(
                vault: vault, password: password, acceptRollback: acceptRollback)
        } catch {
            await failUnlock(error)
        }
    }

    /// Shared unlock tail for create + unlock: runs the KDF (blocking
    /// this actor, deliberately — the UI thread stays free), performs
    /// the v0→v1 migration transparently when needed (CED-13 WS C.1),
    /// opens the single writer, TOFU-registers this device, adopts the
    /// session into actor storage, starts the snapshot feed, and
    /// hard-tombstones expired soft-deletes.
    private func adoptUnlocked(
        vault: SealedVault, password: String, acceptRollback: Bool = false
    ) async {
        let s: UnlockSession
        do {
            let pw = try SecureBytes(nfcNormalizedPassword: password)
            let identity = try deviceKeyStore.loadOrCreateIdentity()
            s = try vault.unlock(
                password: pw, identity: identity, deviceName: deviceName,
                rollbackStore: rollbackStore, acceptRollback: acceptRollback)
        } catch {
            await failUnlock(error)
            return
        }

        let g: Gallery
        do {
            g = try s.openGallery()
        } catch {
            // galleryAlreadyOpen — single-scene policy: report "open
            // elsewhere", release this session's key custody now.
            s.lock(drainDeadline: 0)
            phase = .locked
            await publishPhase()
            await notifyUnlockFailure(mapUnlockError(error))
            return
        }

        session = consume s
        sessionLive = true
        gallery = g
        chunkProvider = vault.makeChunkProvider()
        index = MediaIndex()
        recentlyDeletedStore = RecentlyDeletedStore(
            fileURL: container.recentlyDeletedURL(galleryID: vault.meta.galleryID))
        phase = .unlocked(importing: false)
        await publishPhase()

        // TOFU self-registration at first write-capable unlock (WS
        // A.2): a no-op when already listed. A failure here is not an
        // unlock failure — registration also folds into the next
        // commit automatically.
        try? await g.ensureDeviceRegistered()

        startSnapshotFeed(g)

        // 30-day expiry (WS C.2): expired soft-deletes become hard
        // tombstones for the whole aggregate.
        await purgeExpiredSoftDeletes()
    }

    private func failUnlock(_ error: Error) async {
        if let failure = mapGalleryFailure(error) {
            phase = .galleryError(failure)
            await publishPhase()
            return
        }
        phase = .locked
        await publishPhase()
        await notifyUnlockFailure(mapUnlockError(error))
    }

    // MARK: - Snapshot feed (Codex B4)

    /// One task per unlocked session, consuming `snapshotStream()` —
    /// NEVER the unlock-frozen `UnlockSession.snapshot()`. Captures
    /// the Sendable `Gallery` actor ref and weak self only.
    private func startSnapshotFeed(_ gallery: Gallery) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            let stream = await gallery.snapshotStream()
            for await snapshot in stream {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.ingest(snapshot, from: gallery)
            }
        }
    }

    private func ingest(_ snapshot: InventorySnapshot, from gallery: Gallery) async {
        guard phase.isUnlocked, self.gallery === gallery else { return }
        latestSnapshot = snapshot
        // Fresh reader per committed generation: the previous reader
        // cannot see entries committed after it was made.
        let reader = await gallery.makeReader()
        for file in snapshot.files where !index.knows(file.fileID) {
            do {
                index.record(file.fileID, metadata: try reader.metadata(for: file.fileID))
            } catch {
                // vaultLocked: lock raced the feed — the feed task is
                // about to be cancelled; stop decoding.
                return
            }
        }
        let allItems = index.resolvedItems(in: snapshot)
        // Soft-delete split (CED-13 WS C.2): soft-deleted aggregates
        // leave the grid but stay renderable in Recently Deleted —
        // their entries are untouched until purge/expiry.
        let softDeleted = recentlyDeletedStore?.all ?? []
        let hiddenOriginals = Set(softDeleted.compactMap(\.originalFileID))
        let items = allItems.filter { !hiddenOriginals.contains($0.id) }
        let deletedAtByID = Dictionary(
            uniqueKeysWithValues: softDeleted.compactMap { agg in
                agg.originalFileID.map { ($0, agg.deletedAt) }
            })
        let recentlyDeleted =
            allItems.compactMap { item -> RecentlyDeletedItem? in
                guard let deletedAt = deletedAtByID[item.id] else { return nil }
                return RecentlyDeletedItem(
                    item: item, deletedAt: deletedAt,
                    expiresAt: deletedAt.addingTimeInterval(RecentlyDeletedStore.retention))
            }
            .sorted { $0.deletedAt > $1.deletedAt }
        // Ledger hygiene: rows whose entries vanished from the
        // manifest (purged elsewhere) are dropped.
        recentlyDeletedStore?.compact(keepingKnown: Set(allItems.map(\.id)))
        let report = IndexReport(
            orphanThumbnails: index.orphanThumbnails.count,
            missingThumbnails: index.missingThumbnails.count,
            undecodableEntries: index.undecodable.count)
        // Streaming reader rides the same per-generation cadence,
        // decrypting through the sealed-plane provider into the
        // playback cache (CED-12 WS A).
        var streamingReader: StreamingReader?
        if let chunkProvider, let playbackCache {
            streamingReader = await gallery.makeStreamingReader(
                provider: chunkProvider, cache: playbackCache)
        }
        let streaming = streamingReader
        // Re-check AFTER the awaits above (CED-15): a lock that ran
        // to completion while this ingest was suspended (actor
        // reentrancy) must not let a stale pre-lock item list paint
        // over the cleared UI state.
        guard phase.isUnlocked, self.gallery === gallery else { return }
        let sink = self.sink
        await MainActor.run {
            sink?.readerChanged(reader)
            sink?.streamingReaderChanged(streaming)
            sink?.itemsChanged(items, report: report)
            sink?.recentlyDeletedChanged(recentlyDeleted)
        }
    }

    // MARK: - Two-tier delete (CED-13 WS C.2)

    /// The media AGGREGATE for a top-level item: original + linked
    /// thumbnail + Live-Photo video — resolved from the CURRENT index
    /// so purge tombstones cover every member (reviews B13/Q6).
    private func aggregateMembers(of originalID: FileID) -> [FileID] {
        guard let snapshot = latestSnapshot else { return [originalID] }
        let items = index.resolvedItems(in: snapshot)
        guard let item = items.first(where: { $0.id == originalID }) else {
            return [originalID]
        }
        return [item.id] + [item.thumbnailID, item.livePhotoVideoID].compactMap { $0 }
    }

    /// Tier 1 — "delete for myself": soft, device-local, restorable.
    /// The manifest is untouched; the aggregate moves to Recently
    /// Deleted for 30 days.
    func softDeleteItems(_ originalIDs: [FileID]) async {
        guard phase.isUnlocked, let gallery, let store = recentlyDeletedStore else { return }
        for id in originalIDs {
            store.softDelete(originalID: id, memberIDs: aggregateMembers(of: id))
        }
        await republishFromCurrentSnapshot(gallery)
    }

    /// Restore clears the soft state; the entries were never touched.
    func restoreDeletedItem(_ originalID: FileID) async {
        guard phase.isUnlocked, let gallery, let store = recentlyDeletedStore else { return }
        store.remove(originalID: originalID)
        await republishFromCurrentSnapshot(gallery)
    }

    /// Tier 2 — "delete for everyone": signed hard Tombstones for the
    /// WHOLE aggregate (single-user semantics: this device is always
    /// authorized). Manual purge from Recently Deleted.
    func purgeDeletedItems(_ originalIDs: [FileID]) async {
        guard phase.isUnlocked, let gallery, let store = recentlyDeletedStore else { return }
        for id in originalIDs {
            // Tombstones COMMIT FIRST; the ledger row is removed only
            // after the durable success (wave-001 codex #6) — a failed
            // commit keeps the row, so the user's "remove permanently"
            // choice is retried rather than silently downgraded to a
            // reappearing grid item.
            let members = store.all.first { $0.originalID == id.description }?
                .memberFileIDs ?? aggregateMembers(of: id)
            do {
                try await gallery.deleteEntries(members)
            } catch {
                Self.logPurgeFailure(error)
                break
            }
            store.remove(originalID: id)
        }
        await republishFromCurrentSnapshot(gallery)
    }

    /// 30-day expiry: expired aggregates hard-tombstone automatically.
    func purgeExpiredSoftDeletes() async {
        guard phase.isUnlocked, let gallery, let store = recentlyDeletedStore else { return }
        let expired = store.expired()
        guard !expired.isEmpty else { return }
        for aggregate in expired {
            do {
                try await gallery.deleteEntries(aggregate.memberFileIDs)
            } catch {
                Self.logPurgeFailure(error)
                return
            }
            if let id = aggregate.originalFileID {
                store.remove(originalID: id)
            }
        }
        await republishFromCurrentSnapshot(gallery)
    }

    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "delete")

    private static func logPurgeFailure(_ error: Error) {
        // Typed vault errors only; never plaintext.
        log.error("purge failed: \(String(describing: error), privacy: .public)")
    }

    /// Re-runs the ingest pipeline over the CURRENT committed snapshot
    /// (soft-delete changes alter presentation without a commit).
    private func republishFromCurrentSnapshot(_ gallery: Gallery) async {
        let snapshot = await gallery.snapshot()
        await ingest(snapshot, from: gallery)
    }

    // MARK: - Import (GOAL WS B)

    func startImport(providers: [any MediaProvider]) async {
        guard case .unlocked(importing: false) = phase, let gallery else { return }
        phase = .unlocked(importing: true)
        await publishPhase()

        // Catch the index up with the CURRENT committed snapshot
        // before capturing the dedup hash set — the snapshot feed
        // fills the index asynchronously, and an import started right
        // after unlock would otherwise miss existing originals and
        // re-import duplicates (wave-001 claude-code #10).
        let current = await gallery.snapshot()
        if !current.files.allSatisfy({ index.knows($0.fileID) }) {
            let reader = await gallery.makeReader()
            for file in current.files where !index.knows(file.fileID) {
                guard let metadata = try? reader.metadata(for: file.fileID) else { break }
                index.record(file.fileID, metadata: metadata)
            }
        }

        let engine = ImportEngine(gallery: gallery, container: container)
        let existing = index.originalContentHashes()
        importTask = Task { [weak self] in
            let summary = await engine.run(providers: providers, existingHashes: existing) {
                [weak self] progress in
                await self?.publishImportProgress(progress)
            }
            await self?.finishImport(summary)
        }
    }

    /// Progress hops through the actor so a CANCELLED import (lock or
    /// gallery switch mid-batch) cannot keep painting old-session
    /// progress — with its provider filenames — over the lock screen
    /// or a DIFFERENT gallery's UI (CED-14 WS A.2): once the teardown
    /// cleared `importTask`, late events are dropped.
    private func publishImportProgress(_ progress: ImportProgress?) async {
        guard importTask != nil else { return }
        let sink = self.sink
        await MainActor.run { sink?.importProgressed(progress) }
    }

    private func finishImport(_ summary: ImportSummary) async {
        // A lock/switch teardown already cleared `importTask` (CED-14
        // WS A.2): this summary belongs to a TORN-DOWN session — its
        // outcomes carry provider filenames, and surfacing it after a
        // DIFFERENT gallery unlocks would leak old-gallery residue
        // across the switch. Staging was wiped by the lock path.
        guard importTask != nil else { return }
        importTask = nil
        container.wipeStaging()  // import-end staging custody (gate 4)
        if case .unlocked = phase {
            phase = .unlocked(importing: false)
            await publishPhase()
        }
        let sink = self.sink
        await MainActor.run {
            sink?.importProgressed(nil)
            sink?.importFinished(summary)
        }
    }

    /// Regenerates a missing thumbnail (Codex B2 recovery rule) from
    /// the decrypted original. Called by the store when the index
    /// reports missing thumbnails.
    func regenerateThumbnail(for originalID: FileID) async {
        guard case .unlocked = phase, let gallery else { return }
        guard let meta = index.metadata(for: originalID), meta.kind == .original else { return }
        guard
            let length = latestSnapshot?.files.first(where: { $0.fileID == originalID })?
                .unpaddedLength
        else { return }
        let reader = await gallery.makeReader()
        do {
            let data = try Self.decryptWhole(fileID: originalID, length: length, reader: reader)
            let thumb = try Thumbnailer.makeThumbnail(from: data)
            var thumbMeta = MediaMetadata(kind: .thumbnail, importedAt: Date())
            thumbMeta.parent = originalID.description
            thumbMeta.uti = "public.jpeg"
            thumbMeta.pixelWidth = thumb.pixelWidth
            thumbMeta.pixelHeight = thumb.pixelHeight
            _ = try await gallery.importBytes(thumb.bytes, metadata: thumbMeta.encoded())
        } catch {
            // Undecodable or locked: leave the no-preview badge; the
            // grid already reports the item damaged/missing.
        }
    }

    // MARK: - Export (CED-15 WS A)

    /// Stages `items` for the share sheet: every selected top-level
    /// entry decrypts to a file in StagingExport/, a Live Photo
    /// contributing TWO file items (still + paired video — Codex B5:
    /// true re-pairing needs PhotoKit write authorization the app
    /// does not hold; documented, deferred). The paired video presents
    /// under the still's stem with its own UTI-derived extension.
    func stageExport(items: [MediaItem]) async -> Result<ExportBatch, ExportError> {
        guard case .unlocked = phase, let gallery, let exportController else {
            return .failure(.vaultLocked)
        }
        var plan: [ExportPlanItem] = []
        for item in items {
            plan.append(
                ExportPlanItem(
                    fileID: item.id, byteLength: item.byteLength,
                    filename: item.filename, uti: item.uti))
            if let videoID = item.livePhotoVideoID {
                let stem = item.filename.map { ($0 as NSString).deletingPathExtension }
                plan.append(
                    ExportPlanItem(
                        fileID: videoID, byteLength: item.livePhotoVideoByteLength,
                        filename: stem, uti: item.livePhotoVideoUTI))
            }
        }
        let reader = await gallery.makeReader()
        do {
            return .success(try await exportController.stage(plan: plan, reader: reader))
        } catch let error as ExportError {
            return .failure(error)
        } catch {
            return .failure(.stagingUnavailable(String(describing: error)))
        }
    }

    /// Share-sheet completion/cancellation sweep for one batch.
    func finishExport(batchID: UUID) async {
        await exportController?.finish(batchID: batchID)
    }

    /// Cover-pipeline source (CED-14 WS B.2): decrypts one ORIGINAL's
    /// bytes into memory for the in-memory downscale→seal pass. Never
    /// touches disk; nil when locked, unknown, or not an original.
    /// The decoded bytes are the DISCLOSED memory residual.
    func decryptOriginalForCover(_ originalID: FileID) async -> Data? {
        guard case .unlocked = phase, let gallery else { return nil }
        guard let meta = index.metadata(for: originalID), meta.kind == .original else {
            return nil
        }
        guard
            let length = latestSnapshot?.files.first(where: { $0.fileID == originalID })?
                .unpaddedLength
        else { return nil }
        let reader = await gallery.makeReader()
        return try? Self.decryptWhole(fileID: originalID, length: length, reader: reader)
    }

    /// Decrypts a whole entry into ordinary-heap Data for ImageIO.
    /// This is the documented residual class (grill Q6): decoded
    /// image material lives in app heap until purge-on-lock.
    static func decryptWhole(fileID: FileID, length: UInt64, reader: ChunkReader) throws -> Data {
        guard length > 0 else { return Data() }
        return try reader.readRange(fileID: fileID, offset: 0, length: Int(length)) { buffer in
            buffer.withUnsafeBytes { Data($0) }
        }
    }

    // MARK: - UI-test seeding (gate 3's 500-photo fixture gallery)

    /// Seeds `count` unique originals + thumbnails directly through
    /// the Gallery actor — the scroll-performance gate needs volume,
    /// not provider fidelity. Unique bytes come from an index suffix
    /// appended after the JPEG EOI marker (decoders ignore trailing
    /// bytes; the dedup hash does not).
    func seedGallery(count: Int) async {
        guard case .unlocked = phase, let gallery else { return }
        guard
            let baseURL = Bundle.main.resourceURL?
                .appendingPathComponent("Fixtures/fixture-0000.jpg"),
            let baseData = try? Data(contentsOf: baseURL),
            let thumb = try? Thumbnailer.makeThumbnail(from: baseData)
        else { return }
        let calendar = Calendar(identifier: .gregorian)
        let epoch = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1)) ?? Date()
        for i in 0..<count {
            var bytes = [UInt8](baseData)
            bytes.append(contentsOf: Array("seed-\(i)".utf8))
            var meta = MediaMetadata(kind: .original, importedAt: Date())
            meta.filename = "seed-\(i).jpg"
            meta.uti = "public.jpeg"
            meta.contentHash = "seed-\(i)"
            meta.dateTaken = calendar.date(byAdding: .hour, value: i * 7, to: epoch)
            do {
                let id = try await gallery.importBytes(bytes, metadata: meta.encoded())
                var thumbMeta = MediaMetadata(kind: .thumbnail, importedAt: Date())
                thumbMeta.parent = id.description
                thumbMeta.uti = "public.jpeg"
                _ = try await gallery.importBytes(thumb.bytes, metadata: thumbMeta.encoded())
            } catch {
                return
            }
        }
    }

    // MARK: - Lock (GOAL WS D, Codex B5)

    /// The one lock path: cancel children, purge the index, consume
    /// the session (drains ≤ `drainDeadline`), wipe staging. Runs on
    /// this actor — off the main actor by construction.
    func lock(drainDeadline: TimeInterval = 0.5) async {
        switch phase {
        case .unlocked, .locking:
            break
        default:
            return
        }
        phase = .locking
        await publishPhase()

        // Playback custody unwinds FIRST (CED-12 WS C.3 ordering):
        // loader requests fail, players release, cache zeroizes —
        // all before the custodian drain below can start.
        for participant in lockParticipants {
            await participant.prepareForLock()
        }

        importTask?.cancel()
        importTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        gallery = nil
        chunkProvider = nil
        index.purge()
        latestSnapshot = nil
        recentlyDeletedStore = nil

        let sink = self.sink
        await MainActor.run {
            sink?.readerChanged(nil)
            sink?.streamingReaderChanged(nil)
            sink?.itemsChanged([], report: IndexReport())
            sink?.recentlyDeletedChanged([])
            sink?.importProgressed(nil)
        }

        if let live = session.take() {
            live.lock(drainDeadline: drainDeadline)
        }
        sessionLive = false
        container.wipeStaging()
        phase = .locked
        await publishPhase()
    }

    /// Teardown (scene death): identical custody guarantees to lock —
    /// dropping the session would drain-zero via deinit anyway, but
    /// the explicit path keeps the transition visible.
    func teardown() async {
        await lock(drainDeadline: 0)
    }

    // MARK: - error mapping (GOAL WS D.5)

    private func mapUnlockError(_ error: Error) -> UnlockFailure {
        guard let vaultError = error as? VaultError else {
            return .other(String(describing: error))
        }
        switch vaultError {
        case .dekUnwrapFailed:
            return .wrongPasswordOrDamagedKeyring
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfterSeconds: retryAfter)
        case .galleryAlreadyOpen:
            return .vaultOpenElsewhere
        case .manifestRolledBack:
            return .restoredFromOlderBackup
        default:
            return .other(String(describing: vaultError))
        }
    }

    private func mapGalleryFailure(_ error: Error) -> GalleryFailure? {
        guard let vaultError = error as? VaultError else { return nil }
        switch vaultError {
        case .noValidInventory:
            return .noValidInventory
        case .authenticationFailed(.inventory):
            return .inventoryTampered
        case .notAVault(let path):
            return .other("not a vault: \(path)")
        default:
            return nil
        }
    }

    // MARK: - test hooks

    /// The live Gallery actor (nil unless unlocked) — recovery tests
    /// commit crash-window states directly through it.
    func debugGallery() -> Gallery? { gallery }

    /// The currently targeted gallery directory (switchboard surface).
    func currentGalleryDirectory() -> URL? { galleryDirectory }

    #if DEBUG
        /// UI-test seam (gate 2's tampered-item leg): flips one byte
        /// in `fileID`'s first chunk ON DISK, so the next streamed
        /// read surfaces the damaged-item state. Compiled out of
        /// Release entirely — this primitive DAMAGES the user's CAS
        /// (wave-001 claude-code #9).
        func debugTamperFirstChunk(of fileID: FileID) {
            guard let dir = galleryDirectory,
                let entry = latestSnapshot?.files.first(where: { $0.fileID == fileID }),
                let address = entry.chunkAddresses.first
            else { return }
            let url =
                dir
                .appendingPathComponent("chunks", isDirectory: true)
                .appendingPathComponent(address.hex)
            guard var bytes = try? Data(contentsOf: url), !bytes.isEmpty else { return }
            bytes[bytes.count / 2] ^= 0xFF
            try? bytes.write(to: url)
        }
    #endif

    /// Gate 5: after lock, no child survives — session consumed,
    /// gallery dropped, snapshot + import tasks cancelled and cleared,
    /// index purged.
    func debugChildrenAreTornDown() -> Bool {
        !sessionLive && gallery == nil && snapshotTask == nil && importTask == nil
            && index.isEmpty && latestSnapshot == nil
    }

    // MARK: - plumbing

    private func publishPhase() async {
        let phase = self.phase
        let sink = self.sink
        await MainActor.run { sink?.phaseChanged(phase) }
    }

    private func notifyUnlockFailure(_ failure: UnlockFailure) async {
        let sink = self.sink
        await MainActor.run { sink?.unlockFailed(failure) }
    }

    /// PER-GALLERY record since CED-14 (WS A.3): keyed by the
    /// authoritative gallery UUID, written after `SealedVault.create`
    /// mints it (the calibration itself still runs before the vault
    /// exists — calibrate-at-creation is unchanged).
    private func persistCalibrationRecord(_ record: KDFCalibrator.Record, galleryID: UUID) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: container.calibrationURL(galleryID: galleryID), options: [.atomic])
    }
}

import Foundation
import Observation
import OSLog
import VaultCore

#if os(iOS)
    import UIKit
#endif

/// MainActor view state. Adopts the coordinator's sink; forwards user
/// intents down to the actor. Owns the two pieces of policy that are
/// deliberately NOT coordinator state: the privacy shield (redaction ≠
/// lock — Codex A2) and the auto-lock preferences (grill Q2).
@MainActor
@Observable
final class VaultStore: VaultUISink, GallerySwitchboardSink {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "lock")

    let coordinator: VaultCoordinator
    private let coordinatorContainer: AppContainer
    private let defaults: UserDefaults
    /// The single switch authority (CED-14 WS A.2): every lock/unlock/
    /// select/create intent below routes through it — the store keeps
    /// POLICY (shield, auto-lock preferences) and view state only.
    let switchboard: GallerySwitchboard
    /// Device-local label access for the list surface (CED-14 WS B.2).
    let labelStore: GalleryLabelStore
    let thumbnails = ThumbnailPipeline()
    /// Playback custody owner (CED-12 WS C.3) — registered with the
    /// coordinator's lock path at bootstrap.
    let playback = PlaybackController()

    // MARK: - CED-14 root routing + list state

    private(set) var route: AppRoute = .starting
    private(set) var registrySnapshot = GallerySnapshot()
    /// The selected gallery's authoritative UUID — the key for every
    /// per-gallery preference below.
    private(set) var selectedGalleryID: UUID?
    /// Decrypted label outcomes for the list tiles (typed: failures
    /// render as generic tiles, never crash — plan review B9).
    private(set) var galleryLabels: [UUID: GalleryLabelOutcome] = [:]
    #if os(iOS)
        /// Decoded cover images. PURGED with the global shield (plan
        /// review Q19): the list stays behind the `.inactive` shield,
        /// and the decoded pixels leave memory when it rises.
        private(set) var coverImages: [UUID: UIImage] = [:]
    #endif

    private(set) var phase: VaultPhase = .starting
    private(set) var items: [MediaItem] = []
    /// Soft-deleted aggregates (CED-13 WS C.2) — the Recently Deleted
    /// screen's data; cleared synchronously on lock.
    private(set) var recentlyDeleted: [RecentlyDeletedItem] = []
    private(set) var indexReport = IndexReport()
    /// Settable: the unlock view clears the rollback-acceptance
    /// failure when its alert is dismissed.
    var lastUnlockFailure: UnlockFailure?
    private(set) var importProgress: ImportProgress?
    /// Last finished batch — drives the import summary sheet,
    /// including the interrupted-batch resume prompt (grill Q8).
    /// Cleared synchronously on lock: outcomes carry provider
    /// filenames, which are app-side plaintext (wave-001 codex #3).
    var lastImportSummary: ImportSummary?
    /// Privacy shield: raised the moment the scene leaves `.active`
    /// (before snapshot capture), lowered on `.active`. Never locks by
    /// itself — but when a lock is PENDING, the shield stays up until
    /// the phase actually reaches `.locked` (wave-001 cc #5 / codex #1
    /// / coderabbit converged: the grace-return path briefly rendered
    /// the unlocked grid unshielded).
    private(set) var shielded = false
    private var lockPending = false

    /// PER-GALLERY since CED-14 (WS A.3): loaded when a gallery is
    /// selected, saved under that gallery's keys. The load itself must
    /// not echo a save (`suppressPreferenceSave`).
    private var suppressPreferenceSave = false
    var lockPreferences: LockPreferences {
        didSet {
            guard !suppressPreferenceSave, let id = selectedGalleryID else { return }
            lockPreferences.save(to: defaults, galleryID: id)
        }
    }

    /// Foreground idle backstop bookkeeping.
    private var lastInteraction = Date()
    private var backgroundedAt: Date?
    private var idleTask: Task<Void, Never>?
    /// Originals already given one regeneration attempt this session —
    /// keeps the on-open recovery pass idempotent so a persistently
    /// undecodable original does not retry every generation.
    private var regenerationAttempted: Set<FileID> = []

    /// `defaults` is injectable so app-HOSTED unit tests never write
    /// preferences into the real app domain — persisted test values
    /// (a 0.2 s idle timeout…) would poison later launches on the
    /// same simulator, including the e2e gate's.
    init(
        coordinator: VaultCoordinator, container: AppContainer,
        switchboard: GallerySwitchboard, labelStore: GalleryLabelStore,
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.coordinatorContainer = container
        self.switchboard = switchboard
        self.labelStore = labelStore
        self.defaults = defaults
        self.lockPreferences = LockPreferences()
    }

    /// One-shot: the root view's `.task` re-runs when a full-screen
    /// UIKit presentation detaches the hosting view, and a second
    /// bootstrap would double-register the playback lock participant.
    private var bootstrapped = false

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await coordinator.attach(sink: self)
        await coordinator.attachPlayback(
            cache: playback.cache, participant: playback)
        // The thumbnail pipeline rides the ONE lock path (CED-14 WS
        // A.2, plan review B2): every teardown purges it before the
        // custodian drain, including gallery switches.
        await coordinator.attachLockParticipant(
            ThumbnailLockParticipant(pipeline: thumbnails))
        await thumbnails.setDamageHandler { [weak self] fileID in
            await self?.markDamaged(fileID)
        }
        await switchboard.attach(sink: self)
        await switchboard.bootstrap()
    }

    // MARK: - intents (all custody transitions route via switchboard)

    func createGallery(password: String, name: String? = nil) {
        lastUnlockFailure = nil
        Task { await switchboard.createGallery(name: name, password: password) }
    }

    func unlock(password: String, acceptRollback: Bool = false) {
        lastUnlockFailure = nil
        Task {
            await switchboard.unlockSelected(
                password: password, acceptRollback: acceptRollback)
        }
    }

    /// From the list: target a gallery (its unlock screen appears).
    func selectGallery(_ id: UUID) {
        lastUnlockFailure = nil
        Task { await switchboard.select(id) }
    }

    /// Back to the list — from a target's unlock screen, or "Switch
    /// Gallery" while unlocked (which locks first, full teardown).
    func backToList() {
        lastUnlockFailure = nil
        Task { await switchboard.backToList() }
    }

    // MARK: - two-tier delete intents (CED-13 WS C.2)

    /// "Remove" from grid/pager: soft — into Recently Deleted.
    func softDelete(_ originalIDs: [FileID]) {
        Task { await coordinator.softDeleteItems(originalIDs) }
    }

    /// Restore from Recently Deleted.
    func restoreDeleted(_ originalID: FileID) {
        Task { await coordinator.restoreDeletedItem(originalID) }
    }

    /// Permanent removal (hard Tombstones for the whole aggregate).
    func purgeDeleted(_ originalIDs: [FileID]) {
        Task { await coordinator.purgeDeletedItems(originalIDs) }
    }

    /// Explicit lock control (GOAL WS D.1) and every auto-lock path.
    /// Plaintext-bearing UI state clears SYNCHRONOUSLY here; the
    /// teardown transaction (thumbnail purge rides the coordinator's
    /// lock path as a participant since CED-14) runs on the
    /// switchboard under a background-task assertion so iOS lets the
    /// consuming `lock()` finish before suspending the process
    /// (wave-001 cc #4).
    func lock() {
        Self.log.debug("store.lock() requested")
        lockPending = true
        lastImportSummary = nil
        importProgress = nil
        recentlyDeleted = []
        regenerationAttempted = []
        derivedDurations = [:]
        #if os(iOS) && !targetEnvironment(macCatalyst)
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "vault-lock")
            Task {
                await switchboard.lockCurrent()
                if assertion != .invalid {
                    UIApplication.shared.endBackgroundTask(assertion)
                }
            }
        #else
            Task { await switchboard.lockCurrent() }
        #endif
    }

    func startImport(providers: [any MediaProvider]) {
        Task { await coordinator.startImport(providers: providers) }
    }

    /// One regeneration attempt per missing-thumbnail original (the
    /// Codex B2 on-open recovery rule; wired from `itemsChanged` —
    /// wave-001 cc #2 / codex #5 found the previous version dead code).
    func regenerateMissingThumbnails() {
        let candidates = items.filter {
            $0.thumbnailID == nil && !$0.damaged && !regenerationAttempted.contains($0.id)
        }
        guard !candidates.isEmpty else { return }
        for item in candidates { regenerationAttempted.insert(item.id) }
        Task {
            for item in candidates {
                await coordinator.regenerateThumbnail(for: item.id)
            }
        }
    }

    // MARK: - scenePhase policy (GOAL WS D.1/D.2)

    func sceneBecameInactive() {
        Self.log.debug("scene inactive — shield up")
        shielded = true
        // Covers purge with the global shield (CED-14 WS B.2, plan
        // review Q19): the decoded pixels leave memory the moment the
        // opaque shield rises, so no cover can ride the app-switcher
        // snapshot even though the list renders pre-unlock.
        purgeCoverImages()
    }

    func sceneBecameActive() {
        Self.log.debug("scene active")
        // Grace-period policy: an app backgrounded longer than the
        // grace window locks on RETURN (timers do not run while
        // suspended; memory custody during the window is the accepted
        // trade the preference names). The shield stays UP through a
        // pending lock — it drops in phaseChanged when `.locked`
        // lands, never before.
        let mustLock =
            backgroundedAt.map {
                lockPreferences.backgroundPolicy == .grace
                    && Date().timeIntervalSince($0) > lockPreferences.gracePeriod
            } ?? false
        backgroundedAt = nil
        if mustLock {
            lock()
        } else if !lockPending {
            shielded = false
            noteInteraction()
        }
        reloadLabels()
    }

    func sceneEnteredBackground() {
        Self.log.debug(
            "scene background policy=\(self.lockPreferences.backgroundPolicy.rawValue, privacy: .public)"
        )
        shielded = true
        backgroundedAt = Date()
        switch lockPreferences.backgroundPolicy {
        case .immediate:
            lock()
        case .grace, .off:
            break
        }
    }

    // MARK: - idle backstop

    /// Any user interaction (grid scrolls, taps, navigation).
    func noteInteraction() {
        lastInteraction = Date()
    }

    func startIdleWatch(pollInterval: Duration = .seconds(15)) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard let self else { return }
                let timeout = self.lockPreferences.idleTimeout
                guard timeout > 0, self.phase.isUnlocked, !self.shielded else { continue }
                if Date().timeIntervalSince(self.lastInteraction) >= timeout {
                    Self.log.debug("idle backstop fired")
                    self.lock()
                }
            }
        }
    }

    // MARK: - GallerySwitchboardSink (CED-14 WS B.1)

    func routeChanged(_ route: AppRoute) {
        self.route = route
        if case .gallery(let record) = route {
            // Per-gallery policy arms at selection (WS A.3, plan
            // review Q18): the list held no DEK and needed none; from
            // here this gallery's own preferences govern.
            selectedGalleryID = record.id
            suppressPreferenceSave = true
            lockPreferences = LockPreferences.load(from: defaults, galleryID: record.id)
            suppressPreferenceSave = false
        } else {
            selectedGalleryID = nil
        }
        if case .list = route {
            reloadLabels()
        } else {
            // Covers render only on the list: leaving it drops both
            // the decoded images and the cached compressed bytes
            // (wave-001 claude-code #2).
            purgeCoverImages()
        }
    }

    func registryChanged(_ snapshot: GallerySnapshot) {
        registrySnapshot = snapshot
        reloadLabels()
    }

    // MARK: - VaultUISink

    func phaseChanged(_ phase: VaultPhase) {
        self.phase = phase
        // The pager must not outlive the unlocked phase — its pages
        // hold decoded plaintext imagery (CED-12 WS C.3).
        if !phase.isUnlocked { MediaPagerPresenter.dismissActive() }
        if case .unlocked = phase { noteInteraction() }
        if case .unlocked = phase, lockPending {
            // A lock requested while an unlock was in flight must WIN
            // (CED-14 gate 3's backgrounding-mid-target-KDF race): the
            // two transactions land on the switchboard in either
            // order, and if the teardown processed first — a no-op,
            // nothing was live yet — the unlock would otherwise settle
            // an unlocked vault in the background. Re-issue until the
            // pending lock lands; the shield stays up throughout.
            Self.log.debug("unlock settled under a pending lock — re-locking")
            Task { await switchboard.lockCurrent() }
        }
        if phase == .locking {
            // EVERY teardown path — user lock, scene lock, idle
            // backstop, gallery switch — clears plaintext-adjacent UI
            // state the moment the coordinator enters `.locking`,
            // before its participant sweep and custodian drain (CED-14
            // WS A.2, plan review B2). `store.lock()` also clears
            // synchronously for same-frame UX; this is the structural
            // backstop for switchboard-initiated teardowns.
            lastImportSummary = nil
            importProgress = nil
            recentlyDeleted = []
            regenerationAttempted = []
            derivedDurations = [:]
        }
        if phase == .locked {
            lockPending = false
            // The shield outlives the lock only while the scene is
            // away; a foreground lock lands on the unlock screen.
            if backgroundedAt == nil { shielded = false }
        }
    }

    func unlockFailed(_ failure: UnlockFailure) {
        lastUnlockFailure = failure
    }

    func itemsChanged(_ items: [MediaItem], report: IndexReport) {
        // Preserve damage flags already learned from failed reads.
        let damaged = Set(self.items.filter(\.damaged).map(\.id))
        self.items = items.map { item in
            var item = item
            if damaged.contains(item.id) { item.damaged = true }
            return item
        }
        self.indexReport = report
        // On-open recovery (Codex B2): heal missing thumbnails as the
        // index reports them.
        if report.missingThumbnails > 0, phase.isUnlocked {
            regenerateMissingThumbnails()
        }
    }

    func recentlyDeletedChanged(_ items: [RecentlyDeletedItem]) {
        recentlyDeleted = items
    }

    func readerChanged(_ reader: ChunkReader?) {
        Task { await thumbnails.setReader(reader) }
    }

    func streamingReaderChanged(_ reader: StreamingReader?) {
        playback.setReader(reader)
    }

    func importProgressed(_ progress: ImportProgress?) {
        importProgress = progress
    }

    func importFinished(_ summary: ImportSummary) {
        // A summary arriving after (or during) a lock is dropped: its
        // outcomes carry filenames, and the locked UI must hold no
        // import residue.
        guard !lockPending, phase.isUnlocked else { return }
        lastImportSummary = summary
    }

    /// The persisted calibration record (WS D.4) for the Settings
    /// display — the device benchmark's data source. PER-GALLERY since
    /// CED-14 (WS A.3): the selected gallery's record.
    func loadCalibrationRecord() -> KDFCalibrator.Record? {
        guard let id = selectedGalleryID else { return nil }
        guard let data = try? Data(contentsOf: coordinatorContainer.calibrationURL(galleryID: id))
        else { return nil }
        return try? JSONDecoder().decode(KDFCalibrator.Record.self, from: data)
    }

    // MARK: - Device-local labels (CED-14 WS B.2)

    /// Re-reads every discovered gallery's label. Reads are cheap
    /// (small sealed files); failures are typed and degrade to
    /// generic tiles. Cover material — compressed AND decoded — is
    /// held ONLY while the list is the visible surface and the shield
    /// is down (wave-001 claude-code #1/#2): covers render nowhere
    /// else, so off-list the cache keeps names only.
    func reloadLabels() {
        var coversWanted = false
        if case .list = route { coversWanted = !shielded }
        var labels: [UUID: GalleryLabelOutcome] = [:]
        for record in registrySnapshot.records {
            var outcome = labelStore.label(for: record.id)
            if !coversWanted, case .labeled(var label) = outcome, label.coverJPEG != nil {
                label.coverJPEG = nil
                outcome = .labeled(label)
            }
            labels[record.id] = outcome
        }
        galleryLabels = labels
        #if os(iOS)
            var covers: [UUID: UIImage] = [:]
            if coversWanted {
                for (id, outcome) in labels {
                    if case .labeled(let label) = outcome, let jpeg = label.coverJPEG,
                        let image = UIImage(data: jpeg)
                    {
                        covers[id] = image
                    }
                }
            }
            coverImages = covers
        #endif
    }

    /// Drops BOTH cover forms from memory: the decoded images and the
    /// compressed bytes cached in `galleryLabels` (wave-001
    /// claude-code #1 — "covers purge with the shield" means the
    /// plaintext, not just the rendered pixels). Names stay for the
    /// locked-list tiles.
    private func purgeCoverImages() {
        #if os(iOS)
            coverImages = [:]
        #endif
        for (id, outcome) in galleryLabels {
            if case .labeled(var label) = outcome, label.coverJPEG != nil {
                label.coverJPEG = nil
                galleryLabels[id] = .labeled(label)
            }
        }
    }

    /// The selected gallery's display name (nil = unlabeled).
    var selectedGalleryName: String? {
        guard let id = selectedGalleryID,
            case .labeled(let label) = galleryLabels[id] ?? labelStore.label(for: id)
        else { return nil }
        return label.name
    }

    /// Sets/clears the selected gallery's device-local name.
    func setGalleryName(_ name: String) {
        guard let id = selectedGalleryID else { return }
        var label = labelStore.currentLabel(for: id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        label.name = trimmed.isEmpty ? nil : trimmed
        do {
            try labelStore.setLabel(label, for: id)
        } catch {
            Self.log.error(
                "gallery name write failed: \(String(describing: error), privacy: .public)")
        }
        reloadLabels()
    }

    /// Cover pipeline (WS B.2, plan review B9): decrypt the chosen
    /// original → downscale IN MEMORY → seal under the label key, one
    /// pass, no plaintext file. Explicit per-device opt-in leak
    /// (grill Q1). Only meaningful while this gallery is unlocked.
    func setCover(from originalID: FileID) {
        guard let id = selectedGalleryID else { return }
        Task {
            guard let data = await coordinator.decryptOriginalForCover(originalID) else {
                return
            }
            do {
                let cover = try GalleryLabelStore.makeCoverJPEG(fromDecryptedOriginal: data)
                var label = labelStore.currentLabel(for: id)
                label.coverJPEG = cover
                try labelStore.setLabel(label, for: id)
                reloadLabels()
            } catch {
                Self.log.error(
                    "cover pipeline failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func markDamaged(_ fileID: FileID) {
        guard let i = items.firstIndex(where: { $0.id == fileID }) else { return }
        items[i].damaged = true
    }

    // MARK: - Q7 duration backfill (session-scoped)

    /// Durations derived lazily from streamed assets on first open —
    /// the defined recovery for pre-CED-12 paired Live-Photo videos,
    /// whose v1 metadata carries none (inventory blobs are immutable,
    /// so the backfill is in-memory for the unlocked session only).
    private(set) var derivedDurations: [FileID: Double] = [:]

    func recordDerivedDuration(_ seconds: Double, for fileID: FileID) {
        derivedDurations[fileID] = seconds
    }

    /// Route for the "Switch Gallery" affordance: shown whenever more
    /// than one gallery (or any discovery failure) exists.
    var canSwitchGalleries: Bool {
        registrySnapshot.records.count + registrySnapshot.failures.count > 1
    }

    #if DEBUG
        /// UI-test seam: tampers the newest PLAYABLE video's first
        /// chunk on disk and purges the playback cache, so reopening
        /// it streams the damaged bytes cold (gate 2's tampered-item
        /// leg). DEBUG-only: this WRITES corrupted bytes into the CAS.
        func debugTamperNewestPlayableVideo() {
            guard let video = items.first(where: { $0.isVideo && $0.thumbnailID != nil })
            else { return }
            Task {
                await coordinator.debugTamperFirstChunk(of: video.id)
                await playback.cache.purge()
            }
        }
    #endif
}

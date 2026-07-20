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
final class VaultStore: VaultUISink {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "lock")

    let coordinator: VaultCoordinator
    private let coordinatorContainer: AppContainer
    private let defaults: UserDefaults
    let thumbnails = ThumbnailPipeline()
    /// Playback custody owner (CED-12 WS C.3) — registered with the
    /// coordinator's lock path at bootstrap.
    let playback = PlaybackController()

    private(set) var phase: VaultPhase = .starting
    private(set) var items: [MediaItem] = []
    private(set) var indexReport = IndexReport()
    private(set) var lastUnlockFailure: UnlockFailure?
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

    var lockPreferences: LockPreferences {
        didSet { lockPreferences.save(to: defaults) }
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
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.coordinatorContainer = container
        self.defaults = defaults
        self.lockPreferences = LockPreferences.load(from: defaults)
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
        await thumbnails.setDamageHandler { [weak self] fileID in
            await self?.markDamaged(fileID)
        }
        await coordinator.start()
    }

    // MARK: - intents

    func createGallery(password: String) {
        lastUnlockFailure = nil
        Task { await coordinator.createGallery(password: password) }
    }

    func unlock(password: String) {
        lastUnlockFailure = nil
        Task { await coordinator.unlock(password: password) }
    }

    /// Explicit lock control (GOAL WS D.1) and every auto-lock path.
    /// Plaintext-bearing UI state clears SYNCHRONOUSLY here; the key
    /// drain runs on the coordinator under a background-task assertion
    /// so iOS lets the consuming `lock()` finish before suspending the
    /// process (wave-001 cc #4).
    func lock() {
        Self.log.debug("store.lock() requested")
        lockPending = true
        lastImportSummary = nil
        importProgress = nil
        regenerationAttempted = []
        #if os(iOS) && !targetEnvironment(macCatalyst)
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "vault-lock")
            Task {
                await lockAndPurge()
                if assertion != .invalid {
                    UIApplication.shared.endBackgroundTask(assertion)
                }
            }
        #else
            Task { await lockAndPurge() }
        #endif
    }

    private func lockAndPurge() async {
        await thumbnails.purge()
        await coordinator.lock()
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

    // MARK: - VaultUISink

    func phaseChanged(_ phase: VaultPhase) {
        self.phase = phase
        // The pager must not outlive the unlocked phase — its pages
        // hold decoded plaintext imagery (CED-12 WS C.3).
        if !phase.isUnlocked { MediaPagerPresenter.dismissActive() }
        if case .unlocked = phase { noteInteraction() }
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
    /// display — the device benchmark's data source.
    func loadCalibrationRecord() -> KDFCalibrator.Record? {
        let url = coordinatorContainer.vaultRoot.appendingPathComponent("calibration.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KDFCalibrator.Record.self, from: data)
    }

    func markDamaged(_ fileID: FileID) {
        guard let i = items.firstIndex(where: { $0.id == fileID }) else { return }
        items[i].damaged = true
    }

    /// UI-test seam: tampers the newest PLAYABLE video's first chunk
    /// on disk and purges the playback cache, so reopening it streams
    /// the damaged bytes cold (gate 2's tampered-item leg).
    func debugTamperNewestPlayableVideo() {
        guard let video = items.first(where: { $0.isVideo && $0.thumbnailID != nil })
        else { return }
        Task {
            await coordinator.debugTamperFirstChunk(of: video.id)
            await playback.cache.purge()
        }
    }
}

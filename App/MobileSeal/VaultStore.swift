import Foundation
import Observation
import VaultCore

/// MainActor view state. Adopts the coordinator's sink; forwards user
/// intents down to the actor. Owns the two pieces of policy that are
/// deliberately NOT coordinator state: the privacy shield (redaction ≠
/// lock — Codex A2) and the auto-lock preferences (grill Q2).
@MainActor
@Observable
final class VaultStore: VaultUISink {
    let coordinator: VaultCoordinator
    private let coordinatorContainer: AppContainer
    private let defaults: UserDefaults
    let thumbnails = ThumbnailPipeline()

    private(set) var phase: VaultPhase = .starting
    private(set) var items: [MediaItem] = []
    private(set) var indexReport = IndexReport()
    private(set) var lastUnlockFailure: UnlockFailure?
    private(set) var importProgress: ImportProgress?
    /// Last finished batch — drives the import summary sheet,
    /// including the interrupted-batch resume prompt (grill Q8).
    var lastImportSummary: ImportSummary?
    /// Privacy shield: raised the moment the scene leaves `.active`
    /// (before snapshot capture), lowered on `.active`. Never locks by
    /// itself.
    private(set) var shielded = false

    var lockPreferences: LockPreferences {
        didSet { lockPreferences.save(to: defaults) }
    }

    /// Foreground idle backstop bookkeeping.
    private var lastInteraction = Date()
    private var backgroundedAt: Date?
    private var idleTask: Task<Void, Never>?

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

    func bootstrap() async {
        await coordinator.attach(sink: self)
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
    func lock() {
        NSLog("MOBILESEAL-LOCK store.lock() called")
        Task { await lockAndPurge() }
    }

    private func lockAndPurge() async {
        await thumbnails.purge()
        await coordinator.lock()
    }

    func startImport(providers: [any MediaProvider]) {
        Task { await coordinator.startImport(providers: providers) }
    }

    func regenerateMissingThumbnails() {
        Task {
            for item in items where item.thumbnailID == nil {
                await coordinator.regenerateThumbnail(for: item.id)
            }
        }
    }

    // MARK: - scenePhase policy (GOAL WS D.1/D.2)

    func sceneBecameInactive() {
        NSLog("MOBILESEAL-SCENE inactive")
        shielded = true
    }

    func sceneBecameActive() {
        NSLog("MOBILESEAL-SCENE active")
        // Grace-period policy: an app backgrounded longer than the
        // grace window locks on RETURN (timers do not run while
        // suspended; memory custody during the window is the accepted
        // trade the preference names).
        if let away = backgroundedAt,
            lockPreferences.backgroundPolicy == .grace,
            Date().timeIntervalSince(away) > LockPreferences.gracePeriod
        {
            lock()
        }
        backgroundedAt = nil
        shielded = false
        noteInteraction()
    }

    func sceneEnteredBackground() {
        NSLog("MOBILESEAL-SCENE background policy=%@", lockPreferences.backgroundPolicy.rawValue)
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

    /// Any user interaction (the PrivacyWindow reports touches).
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
                    NSLog("MOBILESEAL-LOCK idle backstop fired (timeout=%f)", timeout)
                    self.lock()
                }
            }
        }
    }

    // MARK: - VaultUISink

    func phaseChanged(_ phase: VaultPhase) {
        self.phase = phase
        if case .unlocked = phase { noteInteraction() }
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
    }

    func readerChanged(_ reader: ChunkReader?) {
        Task { await thumbnails.setReader(reader) }
    }

    func importProgressed(_ progress: ImportProgress?) {
        importProgress = progress
    }

    func importFinished(_ summary: ImportSummary) {
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
}

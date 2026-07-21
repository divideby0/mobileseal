import Foundation
import OSLog
import VaultCore

/// The app's root navigation state (CED-14 WS B.1, plan review Q16):
/// what owns the 0/1/N-gallery routing. `.setup` for zero galleries;
/// `.gallery` directly for exactly one healthy gallery (the
/// single-gallery user keeps today's flow — "New Gallery" lives in
/// Settings); `.list` as root whenever more than one gallery — or any
/// discovery failure — exists.
enum AppRoute: Equatable, Sendable {
    case starting
    case setup
    case list
    case gallery(GalleryRecord)
}

/// The switchboard's outbound edge (mirrors `VaultUISink`).
@MainActor
protocol GallerySwitchboardSink: AnyObject, Sendable {
    func routeChanged(_ route: AppRoute)
    func registryChanged(_ snapshot: GallerySnapshot)
}

/// `UserDefaults` is documented thread-safe but not (yet) marked
/// Sendable by Foundation; this scoped wrapper lets the actor hold
/// the injected suite (test seam) without a data-race diagnostic.
struct SendableDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
}

/// The PROCESS-WIDE switch authority (CED-14 WS A.2, plan review
/// B1/B2/B3): every select/unlock/lock transition — scene events,
/// idle-backstop fires, switch taps, unlock tasks, creation — routes
/// through this one actor as a serialized transaction. The per-path
/// `VaultProcessRegistry` cannot enforce the cross-path
/// one-unlocked-at-a-time policy; this actor is where that APP policy
/// lives, layered on top of the coordinator's per-gallery custody.
///
/// The custody invariant it serializes (gate 3): the old gallery's
/// teardown — full lock path: participants swept, plaintext-adjacent
/// UI state cleared, custodian drained, DEK zeroed — COMPLETES before
/// the target gallery's KDF can begin. Structural, not scheduled:
/// `unlockSelected` and `teardownIfLive` are both actor-serialized
/// transactions, and the coordinator refuses `unlock` outside
/// `.locked`.
actor GallerySwitchboard {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "switchboard")

    private let coordinator: VaultCoordinator
    private let registry: GalleryRegistry
    private let labelStore: GalleryLabelStore
    private let defaultsBox: SendableDefaults
    private var defaults: UserDefaults { defaultsBox.defaults }
    private weak var sink: (any GallerySwitchboardSink)?

    private(set) var snapshot = GallerySnapshot()
    private(set) var selected: GalleryRecord?
    /// The gallery whose DEK is live (set when its unlock settles
    /// unlocked, cleared when its teardown completes). At most one by
    /// construction — the one-live-DEK policy's ledger.
    private(set) var liveGalleryID: UUID?

    #if DEBUG
        /// Custody evidence probe (gate 3, plan review A13): DEBUG-only
        /// event trail — never compiled into Release, never exposing
        /// registry internals. Tests assert that every `kdfWillStart`
        /// is preceded by a `teardownCompleted` for whatever DEK was
        /// live, with the coordinator's children provably torn down at
        /// that boundary.
        enum CustodyEvent: Equatable, Sendable {
            case teardownCompleted(UUID)
            case kdfWillStart(UUID)
            case unlockSettled(UUID, unlocked: Bool)
        }
        private(set) var custodyEvents: [CustodyEvent] = []
    #endif

    init(
        coordinator: VaultCoordinator, registry: GalleryRegistry,
        labelStore: GalleryLabelStore, defaults: SendableDefaults = SendableDefaults()
    ) {
        self.coordinator = coordinator
        self.registry = registry
        self.labelStore = labelStore
        self.defaultsBox = defaults
    }

    func attach(sink: any GallerySwitchboardSink) {
        self.sink = sink
    }

    // MARK: - Transaction serialization

    /// The FIFO transaction chain. Actor isolation alone is NOT
    /// enough for gate 3: actors are REENTRANT at suspension points,
    /// so two transitions could interleave at their internal awaits —
    /// a second teardown observing a stale `liveGalleryID` mid-switch
    /// was exactly the double-switch race the adversarial suite
    /// caught. Every public transition funnels through here, making
    /// each one atomic with respect to the others.
    private var transactionTail: Task<Void, Never>?

    private func serialized(_ op: @escaping @Sendable () async -> Void) async {
        let previous = transactionTail
        let next = Task {
            await previous?.value
            await op()
        }
        transactionTail = next
        await next.value
    }

    /// Value-returning transaction (CED-15 WS B.2): same FIFO chain,
    /// for transitions whose caller needs the outcome.
    private func serializedResult<T: Sendable>(
        _ op: @escaping @Sendable () async -> T
    ) async -> T {
        let previous = transactionTail
        let next = Task<T, Never> {
            await previous?.value
            return await op()
        }
        transactionTail = Task { _ = await next.value }
        return await next.value
    }

    // MARK: - Transitions (each = one serialized transaction)

    /// Launch transaction: coordinator startup, registry scan, the
    /// idempotent single-gallery migration (WS B.3), then routing —
    /// an existing single gallery lands in its own flow unchanged
    /// (gate 2's zero-friction relaunch).
    func bootstrap() async {
        await serialized { await self.performBootstrap() }
    }

    /// From the list: target a gallery — its unlock screen appears.
    func select(_ id: UUID) async {
        await serialized { await self.performSelect(id) }
    }

    /// Back to the list (from a target's unlock screen, or "Switch
    /// Gallery" while unlocked — which locks first, by construction).
    func backToList() async {
        await serialized { await self.performBackToList() }
    }

    /// Switch transaction (gate 2): full teardown of whatever is
    /// live, then the target's unlock screen. A wrong target password
    /// leaves the app ON that unlock screen with everything locked
    /// (plan review Q15); Back returns to the list. NOTE (wave-001
    /// claude-code #3): the shipped UI composes switches from
    /// `backToList()` + `select(_:)`; this single-transaction form
    /// exists for the gate-3 double-switch race coverage and any
    /// future direct-switch affordance.
    func switchTo(_ id: UUID) async {
        await serialized { await self.performSwitchTo(id) }
    }

    /// Unlock the selected gallery. The KDF start is recorded AFTER
    /// any live teardown has completed — the gate-3 ordering evidence.
    func unlockSelected(password: String, acceptRollback: Bool = false) async {
        await serialized {
            await self.performUnlockSelected(
                password: password, acceptRollback: acceptRollback)
        }
    }

    /// Locks whatever is live (user lock, scene policy, idle
    /// backstop): the selection is kept — the same gallery's unlock
    /// screen shows next, exactly like today's single-gallery flow.
    func lockCurrent() async {
        await serialized { await self.teardownIfLive() }
    }

    /// Creation transaction (WS A.1): teardown anything live, create
    /// (per-gallery KDF calibration runs inside), record the creation
    /// date, apply the optional device-local name, adopt as selected.
    func createGallery(name: String?, password: String) async {
        await serialized {
            await self.performCreateGallery(name: name, password: password)
        }
    }

    /// Re-scan for the list surface. The ACTIVE gallery's directory is
    /// never re-read while claimed (plan review B4): its cached record
    /// stands in.
    func refreshRegistry() async {
        await serialized { await self.performRefreshRegistry() }
    }

    /// Inbox-claim transaction (CED-15 WS B.2, Codex A4): runs `body`
    /// — claim the batch, start the import — atomically bound to the
    /// LIVE gallery. One serialized transaction, so no switch, lock,
    /// or create can interleave between the liveness check and the
    /// import start; a teardown arriving later follows the normal
    /// import-interruption rules. Returns false (body never runs)
    /// when `galleryID`'s DEK is no longer the live one.
    func claimBoundToLiveGallery(
        _ galleryID: UUID, body: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await serializedResult {
            guard await self.liveGalleryID == galleryID else { return false }
            return await body()
        }
    }

    // MARK: - Transaction bodies (only ever run on the chain)

    private func performBootstrap() async {
        await coordinator.start()
        var snap = registry.scan()
        do {
            try registry.migrateIfNeeded(records: snap.records, defaults: defaults)
        } catch {
            // Migration steps are idempotent and re-run next launch;
            // failing loud-but-alive beats blocking the vault.
            Self.log.fault(
                "single-gallery migration failed (will retry next launch): \(String(describing: error), privacy: .public)"
            )
        }
        snap = registry.scan()
        snapshot = snap
        await publishRegistry()
        if snap.records.count == 1, snap.failures.isEmpty {
            await selectRecord(snap.records[0])
        } else if snap.records.isEmpty, snap.failures.isEmpty {
            await publishRoute(.setup)
        } else {
            await publishRoute(.list)
        }
    }

    private func performSelect(_ id: UUID) async {
        await teardownIfLive()  // defensive: the list should hold no DEK
        guard let record = snapshot.records.first(where: { $0.id == id }) else {
            // A stale tile (its directory vanished since the scan)
            // must not be a silent no-op: rescan and re-publish so
            // the list reflects reality (wave-001 coderabbit #6).
            await performBackToList()
            return
        }
        await selectRecord(record)
    }

    private func performBackToList() async {
        await teardownIfLive()
        if selected != nil {
            await coordinator.deselect()
            selected = nil
        }
        rescanKeepingActive()
        await publishRegistry()
        await publishRoute(.list)
    }

    private func performSwitchTo(_ id: UUID) async {
        await teardownIfLive()
        guard let record = snapshot.records.first(where: { $0.id == id }) else {
            await performBackToList()
            return
        }
        await selectRecord(record)
    }

    private func performUnlockSelected(password: String, acceptRollback: Bool) async {
        await teardownIfLive()  // defensive: unlock screen implies locked
        guard let selected else { return }
        #if DEBUG
            custodyEvents.append(.kdfWillStart(selected.id))
        #endif
        await coordinator.unlock(password: password, acceptRollback: acceptRollback)
        let unlocked = await coordinator.phase.isUnlocked
        if unlocked { liveGalleryID = selected.id }
        #if DEBUG
            custodyEvents.append(.unlockSettled(selected.id, unlocked: unlocked))
        #endif
    }

    private func performCreateGallery(name: String?, password: String) async {
        await teardownIfLive()
        let previouslySelected = selected
        if selected != nil {
            await coordinator.deselect()
            selected = nil
            await publishRoute(.list)
        }
        guard let id = await coordinator.createGallery(password: password) else {
            // Failure already surfaced through the coordinator's
            // sink. Restore whatever was active before the attempt —
            // a single-gallery user creating from Settings must land
            // back in their gallery flow, not stranded on the list
            // (wave-001 coderabbit #7).
            if let previouslySelected {
                await selectRecord(previouslySelected)
            }
            return
        }
        // Crash between create and this record is a covered creation
        // crash point: the next scan self-heals the date (WS B.1).
        let createdAt = Date()
        registry.recordCreated(id: id, at: createdAt)
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            var label = labelStore.currentLabel(for: id)
            label.name = name
            do {
                try labelStore.setLabel(label, for: id)
            } catch {
                Self.log.error(
                    "label write at creation failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        guard let directory = await coordinator.currentGalleryDirectory() else { return }
        let record = GalleryRecord(id: id, directory: directory, createdAt: createdAt)
        selected = record
        // Creation normally adopts unlocked; a failed adoption (the
        // coordinator surfaced it) leaves the new gallery locked on
        // its unlock screen instead.
        if await coordinator.phase.isUnlocked {
            liveGalleryID = id
            #if DEBUG
                // Creation mints and adopts a DEK: model it in the
                // custody trail exactly like an unlock settling.
                custodyEvents.append(.unlockSettled(id, unlocked: true))
            #endif
        }
        rescanKeepingActive()
        await publishRegistry()
        await publishRoute(.gallery(record))
    }

    private func performRefreshRegistry() async {
        rescanKeepingActive()
        await publishRegistry()
    }

    // MARK: - Internals

    private func selectRecord(_ record: GalleryRecord) async {
        await coordinator.select(directory: record.directory)
        selected = record
        await publishRoute(.gallery(record))
    }

    /// The FULL teardown transaction (plan review B2): one call into
    /// the coordinator's single lock path — .locking published (the
    /// store clears plaintext-adjacent UI state), every lock
    /// participant swept (playback custody, thumbnail purge), children
    /// cancelled, custodian drained, DEK zeroed. Never a raw partial
    /// lock. Completes before this actor processes the next
    /// transaction.
    private func teardownIfLive() async {
        let wasLive = liveGalleryID
        await coordinator.lock()
        guard let wasLive else { return }
        #if DEBUG
            let torn = await coordinator.debugChildrenAreTornDown()
            assert(torn, "teardown left live children behind")
            custodyEvents.append(.teardownCompleted(wasLive))
        #endif
        liveGalleryID = nil
    }

    private func rescanKeepingActive() {
        let active = liveGalleryID != nil ? selected : nil
        snapshot = registry.scan(activeRecord: active)
    }

    private func publishRoute(_ route: AppRoute) async {
        let sink = self.sink
        await MainActor.run { sink?.routeChanged(route) }
    }

    private func publishRegistry() async {
        let snapshot = self.snapshot
        let sink = self.sink
        await MainActor.run { sink?.registryChanged(snapshot) }
    }
}

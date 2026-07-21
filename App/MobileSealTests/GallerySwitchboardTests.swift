import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// CED-14 gate 3 (custody half): one-live-DEK proven as CUSTODY
/// EVIDENCE — the old key zeroed and escaped readers revoked BEFORE
/// the target's KDF begins — under switching, rapid multi-switch,
/// backgrounding mid-target-KDF, and switching during import; plus
/// the switch-fail state (plan review Q15) and the label/cover
/// custody canaries. Probes are DEBUG-only (plan review A13);
/// revocation is asserted externally (escaped readers fail closed).
@MainActor
@Suite struct GallerySwitchboardTests {
    static let passwordA = "alpha gallery password"
    static let passwordB = "beta gallery password"

    /// Two-gallery app stack, unlocked in B (the second-created), with
    /// the full store + switchboard wiring `MobileSealApp` uses.
    struct Fixture {
        let container: AppContainer
        let store: VaultStore
        var idA: UUID
        var idB: UUID

        @MainActor
        static func create() async throws -> Fixture {
            let container = try TestSupport.makeContainer()
            let coordinator = VaultCoordinator(
                container: container, calibration: TestSupport.fastCalibration,
                deviceKeyStore: TestDeviceKeyStore(
                    url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
                deviceName: "switchboard-test-device")
            let defaults = UserDefaults(suiteName: "switchboard-\(UUID().uuidString)")!
            let store = TestSupport.makeStore(
                coordinator: coordinator, container: container, defaults: defaults)
            await store.bootstrap()
            guard await TestSupport.waitUntil({ store.route == .setup }) else {
                throw TestError("never reached setup route")
            }
            store.createGallery(password: passwordA, name: "Alpha")
            guard
                await TestSupport.waitUntil({
                    store.phase == .unlocked(importing: false)
                        && store.selectedGalleryID != nil
                })
            else { throw TestError("gallery A never unlocked") }
            let idA = store.selectedGalleryID!

            store.createGallery(password: passwordB, name: "Beta")
            guard
                await TestSupport.waitUntil({
                    store.phase == .unlocked(importing: false)
                        && store.selectedGalleryID != nil && store.selectedGalleryID != idA
                })
            else { throw TestError("gallery B never unlocked") }
            let idB = store.selectedGalleryID!
            return Fixture(container: container, store: store, idA: idA, idB: idB)
        }

        func destroy() async {
            await store.coordinator.teardown()
            TestSupport.removeContainer(container)
        }
    }

    /// The global custody-order invariant over the DEBUG event trail:
    /// replaying the events, a KDF may only start while NO DEK is
    /// live — every unlock that settled `unlocked` must be followed
    /// by its `teardownCompleted` before the next `kdfWillStart`.
    private func assertCustodyOrder(_ events: [GallerySwitchboard.CustodyEvent]) {
        var live: UUID?
        for event in events {
            switch event {
            case .kdfWillStart:
                #expect(live == nil, "KDF started while DEK \(live!) was live: \(events)")
            case .unlockSettled(let id, let unlocked):
                if unlocked { live = id }
            case .teardownCompleted(let id):
                #expect(live == id, "teardown for \(id) but live was \(String(describing: live))")
                live = nil
            }
        }
    }

    // MARK: - Creation + calibration (WS A.1)

    @Test func secondGalleryCreationTearsDownFirstAndCalibratesPerGallery() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }

        // Per-gallery calibration records exist for BOTH galleries.
        for id in [fx.idA, fx.idB] {
            #expect(
                FileManager.default.fileExists(
                    atPath: fx.container.calibrationURL(galleryID: id).path),
                "missing calibration record for \(id)")
        }
        // A's teardown completed during B's creation transaction.
        let events = await fx.store.switchboard.custodyEvents
        #expect(events.contains(.teardownCompleted(fx.idA)))
        #expect(await fx.store.switchboard.liveGalleryID == fx.idB)
        assertCustodyOrder(events)
    }

    // MARK: - The switch custody evidence (gate 3 core)

    @Test func switchRevokesOldReadersAndZeroesBeforeTargetKDF() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }
        let store = fx.store

        // Escape a reader from unlocked B — it must fail CLOSED after
        // the switch teardown (external revocation evidence).
        let gallery = try #require(await store.coordinator.debugGallery())
        let escaped = await gallery.makeReader()
        let snapshot = await gallery.snapshot()

        // Switch = back to the list (locks B), then unlock A.
        store.backToList()
        #expect(await TestSupport.waitUntil { store.route == .list })
        #expect(await store.coordinator.debugChildrenAreTornDown())
        #expect(await store.switchboard.liveGalleryID == nil)
        if let file = snapshot.files.first {
            #expect(throws: VaultError.vaultLocked) {
                try escaped.readRange(fileID: file.fileID, offset: 0, length: 1) { _ in () }
            }
        }

        store.selectGallery(fx.idA)
        #expect(
            await TestSupport.waitUntil {
                if case .gallery(let record) = store.route { return record.id == fx.idA }
                return false
            })
        store.unlock(password: Self.passwordA)
        #expect(
            await TestSupport.waitUntil { store.phase == .unlocked(importing: false) })
        #expect(await store.switchboard.liveGalleryID == fx.idA)

        // Ordering evidence: B's teardown strictly precedes A's KDF.
        let events = await store.switchboard.custodyEvents
        let teardownB = try #require(
            events.lastIndex(of: .teardownCompleted(fx.idB)))
        let kdfA = try #require(events.lastIndex(of: .kdfWillStart(fx.idA)))
        #expect(teardownB < kdfA)
        assertCustodyOrder(events)
    }

    /// Rapid A→B→A switching: every transaction serializes; the trail
    /// never shows a KDF starting while a DEK is live; the final state
    /// is exactly one live DEK (or none).
    @Test func rapidSwitchingKeepsOneLiveDEKInvariant() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }
        let store = fx.store
        let switchboard = store.switchboard

        // Fire a burst of overlapping transactions without awaiting
        // each other (the UI can do exactly this).
        async let s1: Void = switchboard.switchTo(fx.idA)
        async let u1: Void = switchboard.unlockSelected(password: Self.passwordA)
        async let s2: Void = switchboard.switchTo(fx.idB)
        async let u2: Void = switchboard.unlockSelected(password: Self.passwordB)
        async let s3: Void = switchboard.switchTo(fx.idA)
        _ = await (s1, u1, s2, u2, s3)

        let events = await switchboard.custodyEvents
        assertCustodyOrder(events)
        // Terminal state: transaction interleaving is legal in ANY
        // order (actor mailboxes are not FIFO across tasks) — the
        // INVARIANT is at most one live DEK, with the coordinator's
        // state consistent with the ledger.
        let live = await switchboard.liveGalleryID
        if live == nil {
            #expect(await store.coordinator.debugChildrenAreTornDown())
        } else {
            #expect(await store.coordinator.phase.isUnlocked)
            #expect(live == fx.idA || live == fx.idB)
        }
    }

    /// Backgrounding "mid-target-KDF": the scene lock queues behind
    /// the in-flight unlock transaction and tears it down right after
    /// adoption — terminal state locked, nothing live, evidence
    /// ordered.
    @Test func backgroundingDuringUnlockEndsLocked() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }
        let store = fx.store

        store.backToList()
        #expect(await TestSupport.waitUntil { store.route == .list })
        store.selectGallery(fx.idA)
        #expect(
            await TestSupport.waitUntil {
                if case .gallery = store.route { return store.phase == .locked }
                return false
            })

        // Unlock, and background immediately (strict default policy:
        // immediate lock). The two transactions may land on the
        // switchboard in EITHER order; the store's pending-lock
        // backstop makes the lock win regardless.
        store.unlock(password: Self.passwordA)
        store.sceneEnteredBackground()

        // First, the unlock attempt itself must have settled (so the
        // waits below cannot pass vacuously on the pre-unlock state).
        #expect(
            await TestSupport.waitUntil(timeout: .seconds(15)) {
                await store.switchboard.custodyEvents.contains { event in
                    if case .unlockSettled(fx.idA, _) = event { return true }
                    return false
                }
            }, "unlock never settled")
        // Terminal convergence: locked, no live DEK, children gone.
        #expect(
            await TestSupport.waitUntil(timeout: .seconds(15)) {
                let live = await store.switchboard.liveGalleryID
                let torn = await store.coordinator.debugChildrenAreTornDown()
                return store.phase == .locked && live == nil && torn
            }, "backgrounded unlock never converged to locked")
        #expect(store.shielded, "shield must hold through the pending lock")
        assertCustodyOrder(await store.switchboard.custodyEvents)
    }

    /// Switch-fail state (plan review Q15): a wrong target password
    /// leaves the app ON the target's unlock screen with everything
    /// locked; Back returns to the list.
    @Test func wrongTargetPasswordLeavesTargetUnlockScreen() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }
        let store = fx.store

        store.backToList()
        #expect(await TestSupport.waitUntil { store.route == .list })
        store.selectGallery(fx.idA)
        _ = await TestSupport.waitUntil {
            if case .gallery = store.route { return store.phase == .locked }
            return false
        }
        store.unlock(password: "not the password")
        #expect(
            await TestSupport.waitUntil {
                store.lastUnlockFailure == .wrongPasswordOrDamagedKeyring
            })
        // Still on A's unlock surface, nothing live anywhere.
        if case .gallery(let record) = store.route {
            #expect(record.id == fx.idA)
        } else {
            Issue.record("expected gallery route, got \(store.route)")
        }
        #expect(store.phase == .locked)
        #expect(await store.switchboard.liveGalleryID == nil)

        store.backToList()
        #expect(await TestSupport.waitUntil { store.route == .list })
    }

    /// Switching away during an in-flight import: the teardown cancels
    /// the import inside the one lock path, the summary is dropped
    /// (locked UI holds no import residue), and the target unlocks
    /// with only its own content.
    @Test func switchDuringImportCancelsAndCrossesClean() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }
        let store = fx.store

        var slow = FixtureMediaProvider(
            fixtureURL: try TestSupport.fixtureURL("fixture-0002.jpg"))
        slow.behavior = .delay(1.5)
        store.startImport(providers: [slow, slow])
        try? await Task.sleep(for: .milliseconds(150))

        store.backToList()
        #expect(await TestSupport.waitUntil { store.route == .list })
        #expect(await store.coordinator.debugChildrenAreTornDown())
        #expect(store.lastImportSummary == nil)
        #expect(store.importProgress == nil)

        store.selectGallery(fx.idA)
        _ = await TestSupport.waitUntil {
            if case .gallery = store.route { return store.phase == .locked }
            return false
        }
        store.unlock(password: Self.passwordA)
        #expect(
            await TestSupport.waitUntil { store.phase == .unlocked(importing: false) })
        // A is empty — nothing from B's interrupted import crossed.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.items.isEmpty)
        assertCustodyOrder(await store.switchboard.custodyEvents)
    }

    // MARK: - Label + cover custody canaries (WS B.2, gate 3)

    @Test func labelAndCoverNeverTouchGalleryFormatFilesOrDiskPlaintext() async throws {
        let fx = try await Fixture.create()
        defer { Task { await fx.destroy() } }
        let store = fx.store
        let nameCanary = "MOBILESEAL-LABEL-CANARY-1b7d44f0"

        // Import one real image into B, then label + cover it.
        store.startImport(providers: [
            FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL("fixture-0004.jpg"))
        ])
        #expect(await TestSupport.waitUntil { !store.items.isEmpty })
        store.setGalleryName(nameCanary)
        store.setCover(from: store.items[0].id)
        #expect(
            await TestSupport.waitUntil {
                if case .labeled(let label) = store.galleryLabels[fx.idB] ?? .unlabeled {
                    return label.name == nameCanary && label.coverJPEG != nil
                }
                return false
            }, "label + cover never landed")

        guard case .labeled(let label) = store.galleryLabels[fx.idB]!,
            let cover = label.coverJPEG
        else {
            Issue.record("labeled outcome vanished")
            return
        }
        // A distinctive slice of the cover's compressed payload.
        let needle = [UInt8](cover.subdata(in: cover.count / 2..<cover.count / 2 + 32))

        // 1. Nothing under any GALLERY-FORMAT directory carries the
        //    name or the cover (labels are device-local, never synced
        //    into the portable format).
        // 2. Nothing under the WHOLE container (incl. Labels/, whose
        //    records are ciphertext) carries either in plaintext.
        // 3. Nor the process temporary directory (cover pipeline is
        //    memory-only — plan review B9's tmp audit scope).
        let containerBase = fx.container.vaultRoot.deletingLastPathComponent()
        for root in [containerBase, FileManager.default.temporaryDirectory] {
            let nameHits = TestSupport.filesContaining(Array(nameCanary.utf8), under: root)
            #expect(nameHits.isEmpty, "label name in plaintext at: \(nameHits)")
            let coverHits = TestSupport.filesContaining(needle, under: root)
            #expect(coverHits.isEmpty, "cover plaintext at: \(coverHits)")
        }

        // Visible on the LOCKED list (pre-unlock, by design)…
        store.backToList()
        #expect(await TestSupport.waitUntil { store.route == .list })
        #expect(store.coverImages[fx.idB] != nil)
        if case .labeled(let listLabel) = store.galleryLabels[fx.idB] ?? .unlabeled {
            #expect(listLabel.name == nameCanary)
        } else {
            Issue.record("locked list lost the label")
        }

        // …and the decoded cover PURGES with the global shield
        // (plan review Q19).
        store.sceneBecameInactive()
        #expect(store.coverImages.isEmpty)
        store.sceneBecameActive()
        #expect(await TestSupport.waitUntil { store.coverImages[fx.idB] != nil })
    }
}

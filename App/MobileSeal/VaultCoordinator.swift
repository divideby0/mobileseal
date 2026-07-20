import Foundation
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
    case other(String)
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
    /// Fresh reader per committed generation (Codex B4); nil on lock.
    func readerChanged(_ reader: ChunkReader?)
    func importProgressed(_ progress: ImportProgress?)
    func importFinished(_ summary: ImportSummary)
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
    private weak var sink: (any VaultUISink)?

    private var session: UnlockSession?
    /// Mirrors whether `session` holds a value — pattern-matching a
    /// noncopyable Optional in reference storage is a consume, so the
    /// debug probe tracks liveness separately.
    private var sessionLive = false
    private var gallery: Gallery?
    private var galleryDirectory: URL?
    private var index = MediaIndex()
    private var latestSnapshot: InventorySnapshot?
    private var snapshotTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private(set) var phase: VaultPhase = .starting

    init(container: AppContainer, calibration: CalibrationRunner? = nil) {
        self.container = container
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

    // MARK: - Startup

    /// Launch: wipe staging (crash-path custody — gate 4), then route
    /// to setup or unlock.
    func start() async {
        container.wipeStaging()
        if let dir = container.existingGalleryDirectory() {
            galleryDirectory = dir
            phase = .locked
        } else {
            phase = .needsSetup
        }
        await publishPhase()
    }

    // MARK: - Create (calibrate-at-creation, GOAL WS D.4)

    func createGallery(password: String) async {
        guard phase == .needsSetup else { return }
        phase = .creating
        await publishPhase()

        let scratch = container.stagingDir
            .appendingPathComponent("calibration-\(UUID().uuidString)", isDirectory: true)
        let (params, record) = calibration(scratch)
        persistCalibrationRecord(record)

        do {
            let dir = container.newGalleryDirectory()
            let pw = try SecureBytes(nfcNormalizedPassword: password)
            let vault = try SealedVault.create(at: dir, password: pw, kdfParams: params)
            galleryDirectory = dir
            await adoptUnlocked(vault: vault, password: password)
        } catch {
            phase = .needsSetup
            await publishPhase()
            await notifyUnlockFailure(mapUnlockError(error))
        }
    }

    // MARK: - Unlock

    func unlock(password: String) async {
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
            await adoptUnlocked(vault: vault, password: password)
        } catch {
            await failUnlock(error)
        }
    }

    /// Shared unlock tail for create + unlock: runs the KDF (blocking
    /// this actor, deliberately — the UI thread stays free), opens the
    /// single writer, adopts the session into actor storage, starts
    /// the snapshot feed.
    private func adoptUnlocked(vault: SealedVault, password: String) async {
        let s: UnlockSession
        do {
            let pw = try SecureBytes(nfcNormalizedPassword: password)
            s = try vault.unlock(password: pw)
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
        index = MediaIndex()
        phase = .unlocked(importing: false)
        await publishPhase()
        startSnapshotFeed(g)
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
        let items = index.resolvedItems(in: snapshot)
        let report = IndexReport(
            orphanThumbnails: index.orphanThumbnails.count,
            missingThumbnails: index.missingThumbnails.count,
            undecodableEntries: index.undecodable.count)
        let sink = self.sink
        await MainActor.run {
            sink?.readerChanged(reader)
            sink?.itemsChanged(items, report: report)
        }
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
        let sink = self.sink
        importTask = Task { [weak self] in
            let summary = await engine.run(providers: providers, existingHashes: existing) {
                progress in
                await MainActor.run { sink?.importProgressed(progress) }
            }
            await self?.finishImport(summary)
        }
    }

    private func finishImport(_ summary: ImportSummary) async {
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

        importTask?.cancel()
        importTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        gallery = nil
        index.purge()
        latestSnapshot = nil

        let sink = self.sink
        await MainActor.run {
            sink?.readerChanged(nil)
            sink?.itemsChanged([], report: IndexReport())
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

    private func persistCalibrationRecord(_ record: KDFCalibrator.Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let url = container.vaultRoot.appendingPathComponent("calibration.json")
        try? data.write(to: url, options: [.atomic])
    }
}

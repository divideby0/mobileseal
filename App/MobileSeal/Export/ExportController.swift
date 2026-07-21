import Foundation
import OSLog
import VaultCore

/// One file staged for the share sheet: decrypted bytes at `url`
/// (inside StagingExport/), presented to activities under the
/// preserved original `filename` with the stored `uti`.
struct ExportFileItem: Sendable, Equatable {
    let url: URL
    let filename: String
    let uti: String?
}

/// One staged export batch: everything the share sheet will offer,
/// keyed for the completion sweep.
struct ExportBatch: Sendable, Equatable {
    let id: UUID
    let directory: URL
    let files: [ExportFileItem]
}

/// What one vault entry contributes to an export batch (built by the
/// coordinator from the index + snapshot; a Live Photo original
/// contributes TWO plan items — still + paired video — which export as
/// two separate file items, Codex B5: true re-pairing needs PhotoKit
/// write authorization the app does not hold).
struct ExportPlanItem: Sendable, Equatable {
    let fileID: FileID
    let byteLength: UInt64
    /// Preserved original filename when the metadata has one.
    let filename: String?
    let uti: String?
}

enum ExportError: Error, Equatable {
    case vaultLocked
    case stagingUnavailable(String)
    case cancelled
}

/// Owns the export custody lifecycle (CED-15 WS A.2, Codex B2):
/// decrypt-to-file staging into the isolated StagingExport/ root, the
/// per-batch sweep at share completion/cancellation, and — registered
/// in the coordinator's ONE lock path like PlaybackController — the
/// lock-time teardown: cancel in-flight decrypt/writes, await the open
/// file handles' closure, then sweep the whole root. Custody boundary
/// (Codex A5): the canary claim ends at the provider handoff — bytes a
/// chosen activity already copied are the OS's.
actor ExportController: VaultLockParticipant {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "export")

    /// Read slice size for the decrypt-to-file stream: one chunk
    /// (4 MiB) per read keeps peak plaintext memory bounded for large
    /// videos instead of materializing whole files.
    private static let sliceBytes = 4 << 20

    private let container: AppContainer
    /// The in-flight staging task; cancelled by lock/background.
    private var stagingTask: Task<ExportBatch, Error>?
    /// The batch currently offered to a share sheet (staged, not yet
    /// swept). At most one — the share flow is modal.
    private(set) var activeBatch: ExportBatch?
    /// Bumped by every teardown (wave-001 coderabbit #3): a staging
    /// task that finished CONCURRENTLY with a teardown must not hand
    /// its batch to the sheet — the sweep already ran (or is about
    /// to), so the files are dead.
    private var teardownGeneration = 0
    /// Test seam (wave-001 codex #1): awaited between decrypt slices
    /// on the DETACHED staging task — tests park staging here to
    /// deterministically race lock/background cancellation against an
    /// export that has provably started.
    var sliceHook: (@Sendable () async -> Void)?

    init(container: AppContainer) {
        self.container = container
    }

    /// Test seam installer (see `sliceHook`).
    func setSliceHook(_ hook: (@Sendable () async -> Void)?) {
        sliceHook = hook
    }

    /// Test probe: true once a teardown has cancelled the in-flight
    /// staging task (the deterministic-cancellation test sequences its
    /// gate release on this).
    var debugStagingCancelled: Bool {
        stagingTask?.isCancelled ?? false
    }

    /// True while staged plaintext exists or a staging write is in
    /// flight — the scene-background override's trigger (Codex B4).
    var exportInProgress: Bool {
        activeBatch != nil || stagingTask != nil
    }

    /// Decrypts `plan` into a fresh export batch directory, streaming
    /// slice-by-slice through `reader`. Filenames preserve the original
    /// name, dedup-suffixed on collision within the batch (Codex A2).
    /// Throws `ExportError.cancelled` when lock/background tears the
    /// staging down mid-write; the teardown path owns the sweep.
    func stage(plan: [ExportPlanItem], reader: ChunkReader) async throws -> ExportBatch {
        guard stagingTask == nil, activeBatch == nil else {
            throw ExportError.stagingUnavailable("an export is already in progress")
        }
        let container = self.container
        let hook = sliceHook
        // DETACHED, not actor-inherited (wave-001 codex #1): the
        // decrypt/write loop is synchronous per slice, and running it
        // on this actor would starve `prepareForLock`/
        // `cancelActiveExport` until the whole export finished —
        // unbounded lock latency and an uncancellable plaintext write.
        // Off-actor, the loop's per-slice `checkCancellation` observes
        // the teardown's `cancel()` promptly.
        let task = Task<ExportBatch, Error>.detached(priority: .userInitiated) {
            let dir: URL
            do {
                dir = try container.makeExportBatchDirectory()
            } catch {
                throw ExportError.stagingUnavailable(String(describing: error))
            }
            var files: [ExportFileItem] = []
            var usedNames: Set<String> = []
            do {
                for item in plan {
                    try Task.checkCancellation()
                    let name = Self.dedupedName(
                        Self.exportName(filename: item.filename, uti: item.uti, fileID: item.fileID),
                        used: &usedNames)
                    let url = dir.appendingPathComponent(name)
                    try await Self.decryptToFile(
                        fileID: item.fileID, length: item.byteLength,
                        reader: reader, destination: url, sliceHook: hook)
                    files.append(ExportFileItem(url: url, filename: name, uti: item.uti))
                }
            } catch {
                // Failed or cancelled mid-stage: nothing from this
                // batch may survive (handles are closed by the time
                // decryptToFile throws — its defer runs first).
                try? FileManager.default.removeItem(at: dir)
                if error is CancellationError { throw ExportError.cancelled }
                if let vaultError = error as? VaultError, vaultError == .vaultLocked {
                    throw ExportError.vaultLocked
                }
                throw error
            }
            return ExportBatch(id: UUID(), directory: dir, files: files)
        }
        stagingTask = task
        let generation = teardownGeneration
        defer { stagingTask = nil }
        let batch = try await task.value
        // A teardown that ran while we awaited already swept (or is
        // sweeping) the root: its generation bump makes the handout
        // refusal deterministic (wave-001 coderabbit #3), and the
        // files-exist recheck covers a sweep racing the final write.
        guard teardownGeneration == generation, files(exist: batch) else {
            try? FileManager.default.removeItem(at: batch.directory)
            throw ExportError.cancelled
        }
        activeBatch = batch
        return batch
    }

    /// Share-sheet completion/cancellation: sweep the batch (Codex B13
    /// — completion and cancellation both cancel + sweep; bytes a
    /// chosen activity copied before this are past the custody
    /// boundary).
    func finish(batchID: UUID) {
        guard let batch = activeBatch, batch.id == batchID else { return }
        activeBatch = nil
        do {
            try FileManager.default.removeItem(at: batch.directory)
        } catch {
            Self.log.fault(
                "export batch sweep failed: \(String(describing: error), privacy: .public)")
            assertionFailure("export batch sweep failed: \(error)")
        }
        // Belt-and-braces: the batch dir is the only expected child,
        // but the root sweep keeps the invariant "no batch offered ⇒
        // no plaintext under StagingExport/".
        container.wipeExportStaging()
    }

    /// The scene-background override (Codex B4): on `.background`,
    /// REGARDLESS of the grace/off auto-lock preference, an active
    /// export cancels and sweeps — an open plaintext handoff never
    /// rides a grace window. Same teardown as the lock path, without
    /// locking the vault.
    func cancelActiveExport() async {
        await tearDownExports()
    }

    /// The coordinator's ONE lock path (Codex B2): cancel in-flight
    /// decrypt/writes, await the staging task (its file handles close
    /// on the way out), then sweep the whole export root.
    func prepareForLock() async {
        await tearDownExports()
    }

    private func tearDownExports() async {
        teardownGeneration += 1
        stagingTask?.cancel()
        // Await the cancelled task: its defers close every open handle
        // before we sweep, so no unlinked-but-open plaintext vnode can
        // outlive the sweep (Codex B2).
        _ = try? await stagingTask?.value
        stagingTask = nil
        activeBatch = nil
        container.wipeExportStaging()
    }

    // MARK: - internals

    private func files(exist batch: ExportBatch) -> Bool {
        batch.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Streams one entry's plaintext to `destination` in chunk-sized
    /// slices — bounded memory for large videos, cancellation checked
    /// between slices, the handle closed on every exit path. Runs on
    /// the DETACHED staging task, never this actor.
    private static func decryptToFile(
        fileID: FileID, length: UInt64, reader: ChunkReader, destination: URL,
        sliceHook: (@Sendable () async -> Void)?
    ) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        AppContainer.applyProtection(.completeUnlessOpen, to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while offset < length {
            try Task.checkCancellation()
            if let sliceHook { await sliceHook() }
            try Task.checkCancellation()
            let slice = Int(min(UInt64(Self.sliceBytes), length - offset))
            let data = try reader.readRange(fileID: fileID, offset: offset, length: slice) {
                buffer in
                buffer.withUnsafeBytes { Data($0) }
            }
            try handle.write(contentsOf: data)
            offset += UInt64(slice)
        }
        try handle.close()
    }

    /// The presented filename: the preserved original when the
    /// metadata carries one, else a neutral generated name; an
    /// extension consistent with the stored UTI is appended when the
    /// name has none (Codex A2 — UTI-versus-extension disagreements
    /// confuse Files/AirDrop even with exact bytes).
    static func exportName(filename: String?, uti: String?, fileID: FileID) -> String {
        let base: String
        if let filename, !filename.isEmpty {
            base = (filename as NSString).lastPathComponent
        } else {
            base = "MobileSeal-\(String(fileID.description.prefix(8)))"
        }
        if (base as NSString).pathExtension.isEmpty,
            let ext = Self.preferredExtension(for: uti)
        {
            return "\(base).\(ext)"
        }
        return base
    }

    private static func preferredExtension(for uti: String?) -> String? {
        switch uti {
        case "public.jpeg": return "jpg"
        case "public.heic": return "heic"
        case "public.png": return "png"
        case "com.apple.quicktime-movie": return "mov"
        case "public.mpeg-4": return "mp4"
        case "com.adobe.raw-image": return "dng"
        default: return nil
        }
    }

    /// Collision dedup within a batch: "name.jpg" → "name (1).jpg".
    static func dedupedName(_ name: String, used: inout Set<String>) -> String {
        if used.insert(name).inserted { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var counter = 1
        while true {
            let candidate =
                ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            counter += 1
        }
    }
}

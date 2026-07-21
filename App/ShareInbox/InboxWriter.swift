import Foundation
import UniformTypeIdentifiers
import VaultCore

/// The provider seam (Codex B8, mirroring the app's MediaProvider
/// discipline): the writer talks to attachments through this protocol
/// so the whole commit matrix — success, load failure, disk-full,
/// cancellation, live-photo preference — is testable with fakes; the
/// real `NSItemProvider` adapter is one implementation.
protocol InboxAttachment: Sendable {
    var registeredTypeIdentifiers: [String] { get }
    var suggestedName: String? { get }
    /// Bridges `loadFileRepresentation` semantics: the URL is valid
    /// ONLY inside `handler` — implementations must let the writer
    /// copy before returning (file representations ONLY; there is
    /// deliberately no data-loading fallback on this seam). The
    /// returned closure cancels the in-flight load (wave-001 codex
    /// #3): implementations must then complete `handler` with an
    /// error exactly once.
    @discardableResult
    func loadFileRepresentation(
        typeIdentifier: String, handler: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> @Sendable () -> Void
}

/// Real adapter over `NSItemProvider`. `@unchecked Sendable` carries
/// the documented thread-safety contract, same as PickerMediaProvider.
struct ProviderInboxAttachment: InboxAttachment, @unchecked Sendable {
    let itemProvider: NSItemProvider

    var registeredTypeIdentifiers: [String] { itemProvider.registeredTypeIdentifiers }
    var suggestedName: String? { itemProvider.suggestedName }

    func loadFileRepresentation(
        typeIdentifier: String, handler: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> @Sendable () -> Void {
        // File representations ONLY (Codex B8): loadDataRepresentation
        // would materialize whole objects against the extension's
        // 120 MB budget. The Progress is the cancellation handle
        // (wave-001 codex #3) — cancelling it makes the provider call
        // the completion with an error.
        let progress = itemProvider.loadFileRepresentation(
            forTypeIdentifier: typeIdentifier
        ) { url, error in
            handler(url, error)
        }
        return { progress.cancel() }
    }
}

/// One attachment's staging outcome.
struct InboxWriteOutcome: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case staged(InboxManifest)
        /// Not an image/movie/live-photo — media UTIs only this leg.
        case skippedNotMedia
        case failed(InboxError)
    }

    let index: Int
    let suggestedName: String?
    let status: Status
}

/// Stages share-sheet attachments into the app-group inbox
/// (CED-15 WS B.1) under the atomic commit protocol (Codex B9):
/// payload copied INSIDE the load callback → hash + length computed →
/// manifest written LAST → quota victims evicted only AFTER the
/// commit (wave-001 codex #2: a failed share must never destroy
/// previously-committed items). Concurrency is 1 by construction (a
/// serial loop); disk-full and cancellation produce typed cleanup —
/// a failed item's partial payloads are removed, never stranded. The
/// writer needs no unlock and touches no Keychain.
struct InboxWriter: Sendable {
    let store: InboxStore
    /// Optional best-effort source-app label (Codex A1).
    var sourceApp: String?

    /// Serially stages every attachment. Checks `Task.isCancelled`
    /// between items and between copy/hash/commit steps; an in-flight
    /// provider load is cancelled through its handle (codex #3).
    func stage(attachments: [any InboxAttachment]) async -> [InboxWriteOutcome] {
        var outcomes: [InboxWriteOutcome] = []
        for (index, attachment) in attachments.enumerated() {
            if Task.isCancelled {
                outcomes.append(
                    InboxWriteOutcome(
                        index: index, suggestedName: attachment.suggestedName,
                        status: .failed(.cancelled)))
                continue
            }
            let status = await stageOne(attachment)
            outcomes.append(
                InboxWriteOutcome(
                    index: index, suggestedName: attachment.suggestedName, status: status))
        }
        return outcomes
    }

    private func stageOne(_ attachment: any InboxAttachment) async -> InboxWriteOutcome.Status {
        let itemID = UUID()
        do {
            let staged: [StagedPayload]
            let pairing: InboxManifest.Pairing
            // Preference order mirrors PickerMediaProvider (Codex B10):
            // the live-photo bundle FIRST — enumerating image/movie
            // representations independently would duplicate the asset
            // or lose its pairing.
            if attachment.registeredTypeIdentifiers.contains(UTType.livePhoto.identifier),
                let liveParts = try await stageLivePhotoBundleOrFallThrough(
                    attachment, itemID: itemID)
            {
                staged = liveParts
                pairing = .livePhoto
            } else if let movieType = attachment.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .movie) == true
            }) {
                staged = [
                    try await copyPayload(
                        from: attachment, typeIdentifier: movieType, itemID: itemID,
                        index: 0, role: .video)
                ]
                pairing = .single
            } else if let imageType = attachment.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) {
                staged = [
                    try await copyPayload(
                        from: attachment, typeIdentifier: imageType, itemID: itemID,
                        index: 0, role: .still)
                ]
                pairing = .single
            } else {
                return .skippedNotMedia
            }

            do {
                try Task.checkCancellation()
                // Hash + length AFTER the copy, from OUR bytes — the
                // manifest attests what the inbox holds, not what the
                // provider promised.
                var parts: [InboxManifest.Part] = []
                for payload in staged {
                    let length = try Self.fileLength(of: payload.url)
                    let hash = try MediaHashing.blake2b256Hex(of: payload.url)
                    parts.append(
                        InboxManifest.Part(
                            role: payload.role, file: payload.url.lastPathComponent,
                            originalFilename: payload.originalFilename,
                            uti: payload.uti, byteLength: length, blake2b256: hash))
                }
                try Task.checkCancellation()

                // Quota (Codex A3): the plan is computed BEFORE the
                // commit (a single item that can never fit refuses
                // typed, staging nothing), but victims are evicted
                // only AFTER the incoming manifest is durably
                // committed (wave-001 codex #2) — a writer dying
                // mid-item must never have destroyed older committed
                // items for a share that never landed.
                let incoming = parts.reduce(Int64(0)) { $0 + Int64($1.byteLength) }
                let quotaPlan = try store.planQuota(incomingBytes: incoming)

                let manifest = InboxManifest(
                    schemaVersion: InboxManifest.currentSchemaVersion,
                    itemID: itemID, pairing: pairing, committedAt: Date(),
                    sourceApp: sourceApp, parts: parts)
                try manifest.validate()
                // The COMMIT POINT (Codex B9): the manifest lands last,
                // atomically. A crash anywhere before this line leaves
                // only incomplete payloads for the launch sweep.
                let manifestURL = store.inboxDir.appendingPathComponent(
                    InboxManifest.manifestName(itemID: itemID))
                try manifest.encoded().write(to: manifestURL, options: [.atomic])
                InboxStore.applyCustody(to: manifestURL)
                store.executeQuotaPlan(quotaPlan)
                return .staged(manifest)
            } catch {
                // Typed cleanup: nothing of a failed item survives.
                store.remove(itemID: itemID)
                throw error
            }
        } catch is CancellationError {
            store.remove(itemID: itemID)
            return .failed(.cancelled)
        } catch let error as InboxError {
            store.remove(itemID: itemID)
            return .failed(error)
        } catch {
            store.remove(itemID: itemID)
            return .failed(.copyFailed(String(describing: error)))
        }
    }

    private struct StagedPayload: Sendable {
        let url: URL
        let role: InboxManifest.PartRole
        let uti: String?
        let originalFilename: String?
    }

    /// Live-photo intake with an honest fallback contract (wave-001
    /// coderabbit #4): a provider that ADVERTISES a live photo but
    /// cannot deliver the bundle falls through to the plain
    /// image/movie branches (nil return) — but disk-full and
    /// cancellation are REAL refusals and propagate typed instead of
    /// being masked by a doomed fallback.
    private func stageLivePhotoBundleOrFallThrough(
        _ attachment: any InboxAttachment, itemID: UUID
    ) async throws -> [StagedPayload]? {
        do {
            let parts = try await stageLivePhotoBundle(attachment, itemID: itemID)
            return parts.isEmpty ? nil : parts
        } catch InboxError.diskFull(let required, let available) {
            throw InboxError.diskFull(requiredBytes: required, availableBytes: available)
        } catch is CancellationError {
            throw CancellationError()
        } catch InboxError.cancelled {
            throw InboxError.cancelled
        } catch {
            return nil
        }
    }

    /// Live-photo intake (Codex B10): load the ONE bundle
    /// representation, then split its still + video — mirroring
    /// PickerMediaProvider.stageLivePhotoBundle. Partial moves roll
    /// back on failure (wave-001 coderabbit #4) so no orphan payload
    /// blocks the item's fallback or lingers as incomplete state.
    private func stageLivePhotoBundle(
        _ attachment: any InboxAttachment, itemID: UUID
    ) async throws -> [StagedPayload] {
        let tmpDir = store.inboxDir.appendingPathComponent(
            "tmp-\(itemID.uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let bundleURL = try await loadCopy(
            from: attachment, typeIdentifier: UTType.livePhoto.identifier,
            to: tmpDir.appendingPathComponent("bundle", isDirectory: true))
        let contents = try FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: nil)
        var still: (URL, String?)?
        var video: (URL, String?)?
        for file in contents {
            let type = UTType(filenameExtension: file.pathExtension)
            if still == nil, type?.conforms(to: .image) == true {
                still = (file, type?.identifier)
            } else if video == nil, type?.conforms(to: .audiovisualContent) == true {
                video = (file, type?.identifier)
            }
        }
        guard let still, let video else {
            throw InboxError.loadFailed("live photo bundle missing still or video")
        }
        let fm = FileManager.default
        var payloads: [StagedPayload] = []
        do {
            for (index, source) in [(0, still), (1, video)] {
                let dest = store.inboxDir.appendingPathComponent(
                    InboxManifest.payloadName(itemID: itemID, index: index))
                do {
                    // Same-volume move — a rename, no extra space; the
                    // disk check already ran against the whole bundle
                    // inside the load callback.
                    try fm.moveItem(at: source.0, to: dest)
                } catch {
                    throw InboxError.copyFailed(String(describing: error))
                }
                InboxStore.applyCustody(to: dest)
                payloads.append(
                    StagedPayload(
                        url: dest, role: index == 0 ? .still : .pairedVideo, uti: source.1,
                        originalFilename: index == 0
                            ? (attachment.suggestedName ?? source.0.lastPathComponent)
                            : source.0.lastPathComponent))
            }
        } catch {
            for payload in payloads { try? fm.removeItem(at: payload.url) }
            throw error
        }
        return payloads
    }

    private func copyPayload(
        from attachment: any InboxAttachment, typeIdentifier: String,
        itemID: UUID, index: Int, role: InboxManifest.PartRole
    ) async throws -> StagedPayload {
        let dest = store.inboxDir.appendingPathComponent(
            InboxManifest.payloadName(itemID: itemID, index: index))
        let source = try await loadCopy(
            from: attachment, typeIdentifier: typeIdentifier, to: dest)
        InboxStore.applyCustody(to: source)
        return StagedPayload(
            url: dest, role: role, uti: typeIdentifier,
            originalFilename: attachment.suggestedName)
    }

    /// Single-resume, cancellable bridge for the provider handle
    /// (wave-001 codex #3): Task cancellation forwards to the
    /// provider's own cancel, whose completion then resumes the
    /// continuation with an error. `@unchecked Sendable`: all state
    /// behind the lock.
    private final class LoadCancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: (@Sendable () -> Void)?
        private var cancelled = false

        func set(_ handle: @escaping @Sendable () -> Void) {
            lock.lock()
            let fireNow = cancelled
            if !fireNow { self.handle = handle }
            lock.unlock()
            if fireNow { handle() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let handle = self.handle
            self.handle = nil
            lock.unlock()
            handle?()
        }
    }

    /// Bridges the callback seam to async, copying INSIDE the handler
    /// (the source is gone afterwards — Codex B8) after a typed
    /// disk-space check sized over the WHOLE representation —
    /// including a live-photo bundle's contents, not the directory
    /// node (wave-001 claude-code #1).
    private func loadCopy(
        from attachment: any InboxAttachment, typeIdentifier: String, to dest: URL
    ) async throws -> URL {
        let store = self.store
        let box = LoadCancelBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let handle = attachment.loadFileRepresentation(
                    typeIdentifier: typeIdentifier
                ) { url, error in
                    guard let url else {
                        continuation.resume(
                            throwing: Task.isCancelled
                                ? InboxError.cancelled
                                : InboxError.loadFailed(
                                    error.map(String.init(describing:))
                                        ?? "no file representation"))
                        return
                    }
                    do {
                        try Self.diskCheck(for: url, store: store)
                        let fm = FileManager.default
                        try? fm.createDirectory(
                            at: dest.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try fm.copyItem(at: url, to: dest)
                        continuation.resume(returning: dest)
                    } catch let error as InboxError {
                        continuation.resume(throwing: error)
                    } catch {
                        continuation.resume(
                            throwing: InboxError.copyFailed(String(describing: error)))
                    }
                }
                box.set(handle)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Low-disk refusal (Codex B8): the copy itself must not exhaust
    /// storage — require `lowDiskFactor ×` the source's size free.
    private static func diskCheck(for source: URL, store: InboxStore) throws {
        let size = Self.representationSize(of: source)
        guard size > 0 else { return }
        if let available = store.availableCapacity(store.inboxDir),
            available < size * InboxStore.lowDiskFactor
        {
            throw InboxError.diskFull(
                requiredBytes: size * InboxStore.lowDiskFactor, availableBytes: available)
        }
    }

    /// A representation's true byte weight: a file's size, or a
    /// bundle DIRECTORY's recursive content size — the directory
    /// node's own `.size` is meaningless (wave-001 claude-code #1).
    static func representationSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? fileLength(of: url)).map(Int64.init) ?? 0
        }
        guard
            let enumerator = fm.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    static func fileLength(of url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? UInt64 else {
            throw InboxError.copyFailed("unreadable size at \(url.lastPathComponent)")
        }
        return size
    }
}

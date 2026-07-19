import CryptoKit
import Foundation
import VaultCore

/// Per-item batch outcome (GOAL WS B.6): per-item commits — VaultCore's
/// WAL gives per-item atomicity — a failed item stops the batch,
/// committed items stay committed, and the summary reports exactly
/// which items landed.
struct ImportOutcome: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case imported(FileID)
        /// Duplicate content (grill Q5): the app declines to create a
        /// second entry; the summary reports the skip.
        case skippedDuplicate
        case failed(ImportFailure)
        /// Batch stopped before this item was attempted.
        case notAttempted
    }

    let index: Int
    let name: String?
    let status: Status
}

enum ImportFailure: Error, Equatable, Sendable {
    case providerFailed(String)
    /// The still part is not decodable image data (thumbnail
    /// generation failed). The byte-exact original REMAINS committed —
    /// the archive never discards bytes — but the item is reported
    /// failed and renders with a no-preview badge.
    case undecodableMedia
    case lowDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    /// The vault locked mid-batch (backgrounding raced the import).
    case vaultLocked
    case vaultError(String)
}

struct ImportProgress: Sendable, Equatable {
    var total: Int
    var completed: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    var currentName: String?
}

struct ImportSummary: Sendable, Equatable {
    var outcomes: [ImportOutcome] = []
    /// True when the batch was cancelled (backgrounding mid-import —
    /// grill Q8 cancel-and-cleanup); the UI offers the resume prompt.
    var interrupted: Bool = false

    var importedCount: Int {
        outcomes.filter { if case .imported = $0.status { return true } else { return false } }
            .count
    }
    var skippedCount: Int {
        outcomes.filter { $0.status == .skippedDuplicate }.count
    }
    var failedCount: Int {
        outcomes.filter { if case .failed = $0.status { return true } else { return false } }
            .count
    }
}

/// Runs one import batch through VaultCore's `Gallery` actor. Owns the
/// staging lifecycle for the batch (Codex B1): provider output is
/// copied into the protected staging dir, imported from there
/// (`Gallery.importFile` needs a seekable, twice-readable source), and
/// removed at item end — success, failure, or cancellation. The engine
/// never touches the `UnlockSession`; it holds only the Sendable
/// `Gallery` actor reference.
struct ImportEngine: Sendable {
    let gallery: Gallery
    let container: AppContainer

    /// Low-disk pre-flight factor (GOAL WS B.6): refuse when free
    /// space < 2× the estimated bytes still to import.
    static let lowDiskFactor: Int64 = 2

    func run(
        providers: [any MediaProvider],
        existingHashes: Set<String>,
        progress: @Sendable (ImportProgress) async -> Void
    ) async -> ImportSummary {
        var summary = ImportSummary()
        var hashes = existingHashes
        var state = ImportProgress(total: providers.count)
        var observedItemBytes: [Int64] = []

        let batchDir: URL
        do {
            batchDir = try container.makeBatchStagingDirectory()
        } catch {
            summary.outcomes = providers.indices.map {
                ImportOutcome(
                    index: $0, name: providers[$0].suggestedName,
                    status: .failed(.vaultError("staging unavailable: \(error)")))
            }
            return summary
        }
        defer { try? FileManager.default.removeItem(at: batchDir) }

        var stopped = false
        for (i, provider) in providers.enumerated() {
            if stopped || Task.isCancelled {
                if Task.isCancelled { summary.interrupted = true }
                summary.outcomes.append(
                    ImportOutcome(index: i, name: provider.suggestedName, status: .notAttempted))
                continue
            }
            state.currentName = provider.suggestedName
            await progress(state)

            let outcome = await importOne(
                provider, index: i, batchDir: batchDir,
                hashes: &hashes, observedItemBytes: &observedItemBytes,
                remaining: providers.count - i)
            summary.outcomes.append(outcome)

            switch outcome.status {
            case .imported:
                state.completed += 1
            case .skippedDuplicate:
                state.skipped += 1
            case .failed:
                state.failed += 1
                // A failed item stops the batch (GOAL WS B.6);
                // committed items stay committed.
                stopped = true
            case .notAttempted:
                break
            }
            await progress(state)
        }
        if Task.isCancelled { summary.interrupted = true }
        return summary
    }

    private func importOne(
        _ provider: any MediaProvider, index: Int, batchDir: URL,
        hashes: inout Set<String>, observedItemBytes: inout [Int64],
        remaining: Int
    ) async -> ImportOutcome {
        let name = provider.suggestedName
        func fail(_ f: ImportFailure) -> ImportOutcome {
            ImportOutcome(index: index, name: name, status: .failed(f))
        }

        // Per-item staging subdir so cleanup is one directory remove
        // regardless of how many parts the provider produced.
        let itemDir = batchDir.appendingPathComponent("item-\(index)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        } catch {
            return fail(.vaultError("staging unavailable: \(error)"))
        }
        // Staged plaintext lives exactly from here to item end — the
        // custody gate audits this boundary (gate 4).
        defer { try? FileManager.default.removeItem(at: itemDir) }

        let parts: [StagedPart]
        do {
            parts = try await provider.stageParts(into: itemDir)
        } catch is CancellationError {
            return ImportOutcome(index: index, name: name, status: .notAttempted)
        } catch MediaProviderError.cancelled {
            // The user cancelled THIS item's load — skip it without
            // failing the batch (distinct from batch cancellation).
            return ImportOutcome(index: index, name: name, status: .notAttempted)
        } catch let error as MediaProviderError {
            return fail(.providerFailed(String(describing: error)))
        } catch {
            return fail(.providerFailed(String(describing: error)))
        }
        guard let still = parts.first(where: { $0.role == .still }) else {
            return fail(.providerFailed("provider produced no still part"))
        }
        let video = parts.first(where: { $0.role == .pairedVideo })

        // Duplicate check (grill Q5): app-level SHA-256 over the
        // plaintext, kept in the encrypted metadata blob. (VaultCore's
        // own dedup hash is domain-separated and internal; the app
        // cannot ask "would this dedup" without importing, so it keeps
        // an equivalent hash — same identity, media bytes.)
        let contentHash: String
        do {
            contentHash = try Self.sha256Hex(of: still.url)
        } catch {
            return fail(.providerFailed("hashing failed: \(error)"))
        }
        if hashes.contains(contentHash) {
            return ImportOutcome(index: index, name: name, status: .skippedDuplicate)
        }

        // Low-disk pre-flight (GOAL WS B.6): batch estimate = observed
        // mean item size × items remaining; refuse below 2× estimate.
        let itemBytes = parts.reduce(Int64(0)) { $0 + (Self.fileSize(of: $1.url) ?? 0) }
        observedItemBytes.append(itemBytes)
        let meanBytes = observedItemBytes.reduce(0, +) / Int64(observedItemBytes.count)
        let estimate = max(itemBytes, meanBytes * Int64(remaining))
        if let available = Self.availableCapacity(at: container.stagingDir),
            available < estimate * Self.lowDiskFactor
        {
            return fail(
                .lowDiskSpace(
                    requiredBytes: estimate * Self.lowDiskFactor, availableBytes: available))
        }

        if Task.isCancelled {
            return ImportOutcome(index: index, name: name, status: .notAttempted)
        }

        // Thumbnail + properties BEFORE committing anything: an
        // undecodable still is the one failure we can surface without
        // leaving a partially-linked pair behind... except the archive
        // decision (byte-exact always) says commit the original even
        // when no thumbnail can exist. Decode first anyway so the
        // common corrupt-item case fails before touching the vault.
        let thumb: Thumbnailer.Output?
        do {
            thumb = try Thumbnailer.makeThumbnail(from: still.url)
        } catch {
            thumb = nil
        }

        // Original entry (two commits per Codex B2: original first —
        // a crash between them leaves a thumbnail-less original that
        // regenerates on next unlock).
        let now = Date()
        var originalMeta = MediaMetadata(
            kind: .original, importedAt: now)
        originalMeta.filename = name
        originalMeta.uti = still.uti
        originalMeta.contentHash = contentHash
        originalMeta.dateTaken = thumb?.dateTaken
        originalMeta.pixelWidth = thumb?.sourceWidth
        originalMeta.pixelHeight = thumb?.sourceHeight
        originalMeta.isLivePhotoStill = video != nil ? true : nil

        let originalID: FileID
        do {
            originalID = try await gallery.importFile(
                at: still.url, metadata: originalMeta.encoded())
        } catch let error as VaultError {
            return fail(error == .vaultLocked ? .vaultLocked : .vaultError("\(error)"))
        } catch {
            return fail(.vaultError("\(error)"))
        }
        hashes.insert(contentHash)

        // Paired Live Photo video (grill Q4: both parts, linked entry).
        if let video {
            var videoMeta = MediaMetadata(kind: .livePhotoVideo, importedAt: now)
            videoMeta.parent = originalID.description
            videoMeta.uti = video.uti
            do {
                _ = try await gallery.importFile(at: video.url, metadata: videoMeta.encoded())
            } catch let error as VaultError {
                return fail(error == .vaultLocked ? .vaultLocked : .vaultError("\(error)"))
            } catch {
                return fail(.vaultError("\(error)"))
            }
        }

        // Thumbnail entry.
        guard let thumb else {
            // Original committed, no preview possible: item FAILS the
            // batch (gate 2's forced-failure path) while the byte-
            // exact original stays, badged in the grid.
            return fail(.undecodableMedia)
        }
        var thumbMeta = MediaMetadata(kind: .thumbnail, importedAt: now)
        thumbMeta.parent = originalID.description
        thumbMeta.uti = "public.jpeg"
        thumbMeta.pixelWidth = thumb.pixelWidth
        thumbMeta.pixelHeight = thumb.pixelHeight
        do {
            _ = try await gallery.importBytes(thumb.bytes, metadata: thumbMeta.encoded())
        } catch let error as VaultError {
            return fail(error == .vaultLocked ? .vaultLocked : .vaultError("\(error)"))
        } catch {
            return fail(.vaultError("\(error)"))
        }

        return ImportOutcome(index: index, name: name, status: .imported(originalID))
    }

    // MARK: - helpers

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
            .flatMap { $0 }
    }

    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

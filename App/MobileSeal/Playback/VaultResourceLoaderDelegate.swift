import AVFoundation
import Foundation
import UniformTypeIdentifiers
import VaultCore

/// The loader-delegate request state machine (CED-12 WS B.1, Codex
/// B2) — specified, not improvised:
///
///  - AVPlayer sees ONLY the custom `vault://` scheme; no file URL to
///    plaintext exists anywhere.
///  - `contentInformationRequest` is filled with the stored UTI, the
///    UNPADDED length, and `isByteRangeAccessSupported = true`.
///  - Every accepted `dataRequest` enters the request registry and is
///    satisfied incrementally from its `currentOffset` in bounded
///    slices (≤ one chunk per `respond(with:)`), or failed EXACTLY
///    once. `requestsAllDataToEndOfResource` feeds incrementally to
///    EOF, cancellation, or error.
///  - `didCancel` unwinds the registry entry (no finish after cancel).
///  - The delegate serves the byte ranges AVPlayer ACTUALLY requests —
///    overlapping, out-of-order, tail-first — never a time→chunk
///    mapping of its own (Codex B3).
///
/// Error taxonomy for the UX (Codex A6): a vault INTEGRITY error
/// (`chunkUnavailable` / `addressMismatch` / `authenticationFailed`)
/// is recorded observably before the request fails, so the pager can
/// show the damaged-item state; an AVPlayer decode failure with a
/// clean loader means unsupported-but-authentic ("can't play this
/// format"); `vaultLocked` is neither — playback simply ends.
final class VaultResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked
    Sendable
{
    /// One accepted loading request's registry entry: the request
    /// (to fail it on sweep) and its serving task (to cancel).
    private struct Entry {
        let request: AVAssetResourceLoadingRequest
        let task: Task<Void, Never>
    }

    static let scheme = "vault"

    private let reader: StreamingReader
    /// The entry this delegate streams — the controller keys
    /// integrity queries by it (wave-001: `delegates.last` could read
    /// a DIFFERENT page's delegate after a fast swipe).
    let fileID: FileID
    private let contentUTI: String?
    private let contentLength: UInt64
    /// Per-respond slice bound: one chunk (the entry's own chunk
    /// size), so a single respond never touches two cache entries.
    private let sliceBound: Int

    private let lock = NSLock()
    private var registry: [ObjectIdentifier: Entry] = [:]
    private var failedAll = false
    private var integrityFailure = false
    private var accepted = 0
    private var finished = 0
    private var failed = 0
    private var cancelled = 0

    /// The dedicated serial queue handed to
    /// `resourceLoader.setDelegate(_:queue:)`.
    let queue = DispatchQueue(label: "mobileseal.vault-loader")

    init(
        reader: StreamingReader, fileID: FileID, contentUTI: String?,
        contentLength: UInt64, chunkSize: UInt32
    ) {
        self.reader = reader
        self.fileID = fileID
        self.contentUTI = contentUTI
        self.contentLength = contentLength
        self.sliceBound = Int(chunkSize)
    }

    /// Builds the custom-scheme asset wired to this delegate. The URL
    /// carries a fresh UUID so AVFoundation never conflates two
    /// player items' loading state.
    func makeAsset() -> AVURLAsset {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = UUID().uuidString.lowercased()
        components.path = "/\(fileID.description)"
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        accept(loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        accept(renewalRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Unwind: cancel the serving task and drop the entry. The
        // exactly-once discipline means no finishLoading after this.
        lock.lock()
        let entry = registry.removeValue(forKey: ObjectIdentifier(loadingRequest))
        if entry != nil { cancelled += 1 }
        lock.unlock()
        entry?.task.cancel()
    }

    private func accept(_ loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        if failedAll {
            // Lock already swept this delegate: refuse immediately,
            // exactly once, without registering.
            lock.unlock()
            loadingRequest.finishLoading(with: VaultPlaybackError.locked)
            return
        }
        accepted += 1
        let key = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serve(loadingRequest)
        }
        registry[key] = Entry(request: loadingRequest, task: task)
        lock.unlock()
    }

    /// Serves one accepted request to completion: content info, then
    /// the data request in ≤ one-chunk slices from `currentOffset`.
    private func serve(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        if let info = loadingRequest.contentInformationRequest {
            if let uti = contentUTI, let type = UTType(uti) {
                info.contentType = type.identifier
            } else {
                info.contentType = contentUTI
            }
            info.contentLength = Int64(contentLength)
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            finish(loadingRequest, error: nil)
            return
        }

        // The end the registry owes this request: an explicit length,
        // or EOF for requestsAllDataToEndOfResource.
        let end: Int64 =
            dataRequest.requestsAllDataToEndOfResource
            ? Int64(contentLength)
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)

        while dataRequest.currentOffset < end {
            if Task.isCancelled { return }  // didCancel unwound us
            let offset = dataRequest.currentOffset
            guard offset >= 0, offset < Int64(contentLength) else { break }
            // Bounded slice: to the next chunk boundary, never more
            // than one chunk, never past the requested end.
            let withinChunk = Int(offset % Int64(sliceBound))
            let toBoundary = sliceBound - withinChunk
            let want = min(Int64(toBoundary), end - offset, Int64(contentLength) - offset)
            guard want > 0 else { break }
            do {
                let data = try await reader.readRange(
                    fileID: fileID, offset: UInt64(offset), length: Int(want))
                // Respond only while the request is still OURS: the
                // lock sweep (`failAllRequests`) removes the entry
                // and finishes the request from another thread, and
                // responding to a finished request is AVFoundation
                // misuse — the registry lock makes the two mutually
                // exclusive.
                guard respondIfLive(loadingRequest, dataRequest, data) else { return }
            } catch is CancellationError {
                return
            } catch let error as VaultError {
                record(error)
                finish(loadingRequest, error: Self.map(error))
                return
            } catch {
                finish(loadingRequest, error: error)
                return
            }
        }
        finish(loadingRequest, error: nil)
    }

    /// Delivers a slice while holding the registry lock, but only if
    /// the request is still registered (not cancelled, not swept).
    private func respondIfLive(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        _ dataRequest: AVAssetResourceLoadingDataRequest,
        _ data: Data
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard registry[ObjectIdentifier(loadingRequest)] != nil else { return false }
        dataRequest.respond(with: data)
        return true
    }

    /// Exactly-once completion: only a request still in the registry
    /// can finish; everything else was cancelled or swept by
    /// `failAllRequests`.
    private func finish(_ loadingRequest: AVAssetResourceLoadingRequest, error: Error?) {
        lock.lock()
        let entry = registry.removeValue(forKey: ObjectIdentifier(loadingRequest))
        if entry != nil {
            if error == nil { finished += 1 } else { failed += 1 }
        }
        lock.unlock()
        guard entry != nil else { return }
        if let error {
            loadingRequest.finishLoading(with: error)
        } else {
            loadingRequest.finishLoading()
        }
    }

    private func record(_ error: VaultError) {
        switch error {
        case .chunkUnavailable, .addressMismatch, .authenticationFailed, .missingChunk:
            lock.lock()
            integrityFailure = true
            lock.unlock()
        default:
            break
        }
    }

    private static func map(_ error: VaultError) -> Error {
        switch error {
        case .vaultLocked:
            return VaultPlaybackError.locked
        case .chunkUnavailable, .addressMismatch, .authenticationFailed, .missingChunk:
            return VaultPlaybackError.integrity
        case .budgetExhausted:
            return VaultPlaybackError.overBudget
        default:
            return error
        }
    }

    // MARK: - lock path (CED-12 WS C.3 step 1)

    /// Fails every outstanding request exactly once and refuses all
    /// future ones. First step of the lock ordering — runs BEFORE
    /// players stop and the cache purges, so nothing re-enters the
    /// decrypt path behind the sweep.
    func failAllRequests() {
        lock.lock()
        failedAll = true
        let entries = registry
        registry.removeAll()
        failed += entries.count
        lock.unlock()
        // Cancel the serving tasks first so no serve loop responds
        // behind the sweep, then fail each request exactly once
        // (removal from the registry above is what makes the serve
        // loop's own finish() a no-op).
        for (_, entry) in entries {
            entry.task.cancel()
        }
        for (_, entry) in entries where !entry.request.isCancelled {
            entry.request.finishLoading(with: VaultPlaybackError.locked)
        }
    }

    // MARK: - observability (test builds + custody gate)

    var activeRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registry.count
    }

    var sawIntegrityFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return integrityFailure
    }

    var counters: (accepted: Int, finished: Int, failed: Int, cancelled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (accepted, finished, failed, cancelled)
    }
}

/// Playback-plane errors surfaced through `finishLoading(with:)`.
enum VaultPlaybackError: Error {
    /// The vault locked; requests failed closed.
    case locked
    /// A vault integrity failure (missing/tampered chunk) — the
    /// damaged-item UX, never confused with an unsupported codec.
    case integrity
    /// The residency budget refused the read.
    case overBudget
}

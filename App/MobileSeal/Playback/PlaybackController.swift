import AVFoundation
import Foundation
import VaultCore

/// The sole owner of playback custody (CED-12 WS C.3, Codex B5/Q2):
/// one object retains the player, every loader delegate (with its
/// request registry), the resident-plaintext cache, and the current
/// streaming reader — and registers with the coordinator's lock path
/// as a `VaultLockParticipant`.
///
/// Lock ordering (`prepareForLock`): fail all outstanding loader
/// requests → stop/release the player → release readers → purge the
/// cache (zeroize) → and only then does the coordinator's custodian
/// drain proceed. The gate observable is concrete: active-request
/// count == 0 and cache bytes == 0 post-lock. AVFoundation-internal
/// buffers are the documented residual outside that boundary.
///
/// One-active-player rule (grill Q3, Codex A3): player-item creation
/// happens ONLY for the landed pager item; neighbors get at most
/// poster + leading ranges warmed through the provider path, under a
/// generation token that fast swipes invalidate (the thumbnail-purge
/// discipline applied to prefetch).
@MainActor
final class PlaybackController: VaultLockParticipant {
    /// Cache-owned decrypted chunk bytes — production policy; the
    /// injected stream forwards real OS memory-pressure events.
    let cache: ResidentChunkCache

    private(set) var reader: StreamingReader?
    /// Every delegate created this session (landed items). Swept and
    /// released on lock; pruned when a new item lands.
    private var delegates: [VaultResourceLoaderDelegate] = []
    /// The single active player (one-active-player rule).
    private(set) var player: AVPlayer?
    private(set) var activeItemID: FileID?
    /// Prefetch generation token: bumped on every pager landing; a
    /// stale token's warm work is abandoned.
    private var prefetchGeneration = 0
    /// In-flight neighbor warms, keyed by file — RETAINED so a new
    /// landing/release/lock actually CANCELS them (wave-001
    /// convergence: an untracked task cannot be cancelled, and a
    /// before-only token check cancels nothing already started).
    private var warmTasks: [FileID: Task<Void, Never>] = [:]
    /// How much leading media a neighbor warm may pull through the
    /// provider: one default chunk covers moov + first GOP for
    /// fast-start files without draining the budget.
    static let neighborWarmBytes = 4 << 20

    // Gate-4 instrumentation (non-tautological observables).
    private(set) var debugPlayerActivations = 0
    private(set) var debugWarmsStarted = 0
    private(set) var debugWarmsCancelled = 0

    private let pressureSource: DispatchSourceMemoryPressure

    init() {
        let (stream, continuation) = AsyncStream<MemoryPressureEvent>.makeStream()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            let event = source.data
            if event.contains(.warning) || event.contains(.critical) {
                continuation.yield(.pressure)
            } else if event.contains(.normal) {
                continuation.yield(.recovery)
            }
        }
        source.activate()
        pressureSource = source
        cache = ResidentChunkCache(pressure: stream)
    }

    /// Per-generation reader from the coordinator (nil on lock).
    func setReader(_ newReader: StreamingReader?) {
        reader = newReader
    }

    // MARK: - the one-active-player door

    /// Creates (or reuses) THE player, loaded with `fileID` streamed
    /// through a fresh loader delegate. Only the landed pager item
    /// ever gets here.
    func activatePlayer(
        fileID: FileID, uti: String?, byteLength: UInt64
    ) -> AVPlayer? {
        guard let reader else { return nil }
        guard let chunkSize = try? reader.chunkSize(of: fileID) else { return nil }
        invalidatePrefetch()
        debugPlayerActivations += 1

        let delegate = VaultResourceLoaderDelegate(
            reader: reader, fileID: fileID, contentUTI: uti,
            contentLength: byteLength, chunkSize: chunkSize)
        // Sweep delegates whose items are gone: keep the active one's
        // registry alive, drop the rest (their assets are released
        // with their player items).
        delegates.append(delegate)
        let item = AVPlayerItem(asset: delegate.makeAsset())
        let player = self.player ?? AVPlayer()
        player.replaceCurrentItem(with: item)
        self.player = player
        activeItemID = fileID
        pruneInactiveDelegates(keeping: delegate)
        return player
    }

    /// Whether `fileID`'s playback failure was vault damage (loader
    /// integrity error) as opposed to an unsupported codec. Keyed by
    /// file, never "the newest delegate": a probe resolving after a
    /// fast swipe must not read another item's registry (wave-001).
    func sawIntegrityFailure(for fileID: FileID) -> Bool {
        delegates.contains { $0.fileID == fileID && $0.sawIntegrityFailure }
    }

    /// Releases the active player (pager left the item / dismissed).
    func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        activeItemID = nil
        invalidatePrefetch()
    }

    /// Bumps the generation token and CANCELS every in-flight warm —
    /// the actual cancellation mechanism behind the token discipline
    /// (`StreamingReader` checks task cancellation between chunks).
    private func invalidatePrefetch() {
        prefetchGeneration += 1
        for (_, task) in warmTasks {
            task.cancel()
            debugWarmsCancelled += 1
        }
        warmTasks.removeAll()
    }

    private func pruneInactiveDelegates(keeping active: VaultResourceLoaderDelegate?) {
        delegates.removeAll { delegate in
            guard delegate !== active else { return false }
            delegate.failAllRequests()
            return true
        }
    }

    // MARK: - neighbor warming (Codex A3)

    /// Warms a NEIGHBOR's leading ranges through the provider into
    /// the cache — never a player item, never a plaintext copy
    /// (`StreamingReader.warm` populates the budgeted cache with an
    /// empty borrow). The task is RETAINED and cancelled by the next
    /// landing, release, or lock; the token guards the not-yet-started
    /// window.
    func warmNeighbor(fileID: FileID, byteLength: UInt64) {
        guard let reader, byteLength > 0, warmTasks[fileID] == nil else { return }
        let token = prefetchGeneration
        let length = Int(min(byteLength, UInt64(Self.neighborWarmBytes)))
        debugWarmsStarted += 1
        let task = Task { [weak self] in
            guard let self, await self.prefetchGeneration == token else { return }
            try? await reader.warm(fileID: fileID, offset: 0, length: length)
            await self.finishWarm(fileID)
        }
        warmTasks[fileID] = task
    }

    private func finishWarm(_ fileID: FileID) {
        warmTasks[fileID] = nil
    }

    // MARK: - lock path (VaultLockParticipant)

    /// The lock ordering's playback prefix (steps 1–3); the
    /// coordinator's custodian drain is step 4.
    func prepareForLock() async {
        // 1. Fail all outstanding loader requests, refuse new ones —
        //    and cancel every in-flight warm.
        invalidatePrefetch()
        for delegate in delegates {
            delegate.failAllRequests()
        }
        // 2. Stop and release the player (and with it the items
        //    holding the custom-scheme assets).
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        activeItemID = nil
        delegates.removeAll()
        // 3. Release readers and zeroize the cache.
        reader = nil
        await cache.purge()
    }

    // MARK: - observability (custody gate)

    var debugActiveRequestCount: Int {
        delegates.reduce(0) { $0 + $1.activeRequestCount }
    }

    var debugInFlightWarmCount: Int {
        warmTasks.count
    }

    func debugCacheStats() async -> ResidencyStats {
        await cache.stats
    }
}

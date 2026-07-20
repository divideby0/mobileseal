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
    /// How much leading media a neighbor warm may pull through the
    /// provider: one default chunk covers moov + first GOP for
    /// fast-start files without draining the budget.
    static let neighborWarmBytes = 4 << 20

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
        prefetchGeneration += 1

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

    /// Whether the CURRENT item's failure is vault damage (loader
    /// integrity error) as opposed to an unsupported codec.
    var activeItemSawIntegrityFailure: Bool {
        delegates.last?.sawIntegrityFailure ?? false
    }

    /// Releases the active player (pager left the item / dismissed).
    func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        activeItemID = nil
        prefetchGeneration += 1
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
    /// the cache — never a player item. Abandoned when the generation
    /// token moves (fast swipe).
    func warmNeighbor(fileID: FileID, byteLength: UInt64) {
        guard let reader, byteLength > 0 else { return }
        let token = prefetchGeneration
        let length = Int(min(byteLength, UInt64(Self.neighborWarmBytes)))
        Task { [weak self] in
            // Stale-token check before AND after the read: a fast
            // swipe invalidates warm work rather than letting it
            // fight the landed item for budget.
            guard let self, await self.prefetchGeneration == token else { return }
            _ = try? await reader.readRange(fileID: fileID, offset: 0, length: length)
        }
    }

    // MARK: - lock path (VaultLockParticipant)

    /// The lock ordering's playback prefix (steps 1–3); the
    /// coordinator's custodian drain is step 4.
    func prepareForLock() async {
        // 1. Fail all outstanding loader requests, refuse new ones.
        prefetchGeneration += 1
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

    func debugCacheStats() async -> ResidencyStats {
        await cache.stats
    }
}

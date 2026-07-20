import Foundation
import ImageIO
import UIKit
import VaultCore

/// Decrypt-and-decode pipeline for grid thumbnails (GOAL WS C.1,
/// Codex A3): cancelable per-cell tasks, in-flight dedup, and a
/// BOUNDED decoded-image cache. Everything here is app-side plaintext
/// residency — the documented residual class — and `purge()` empties
/// all of it on lock (GOAL WS D.3; gate 5 asserts emptiness).
actor ThumbnailPipeline {
    /// Decoded-cache byte ceiling. 64 MiB ≈ 170 × 512px JPEG decodes —
    /// several screenfuls at 3-4 columns.
    static let cacheCostLimit = 64 << 20

    /// Current-generation reader (Codex B4: replaced per committed
    /// generation; nil after lock — tasks then fail closed).
    private var reader: ChunkReader?
    private var cache: [FileID: UIImage] = [:]
    private var cacheOrder: [FileID] = []
    private var cacheCost = 0
    private var inflight: [FileID: Task<UIImage?, Never>] = [:]
    /// Reported integrity failures (missingChunk / authenticationFailed)
    /// — per-item damaged badge, never silent (GOAL WS D.5).
    private var onDamaged: (@Sendable (FileID) async -> Void)?

    func setReader(_ newReader: ChunkReader?) {
        reader = newReader
    }

    /// The detail viewer borrows the current reader for its own
    /// bounded full-res read.
    func currentReader() -> ChunkReader? {
        reader
    }

    func setDamageHandler(_ handler: @escaping @Sendable (FileID) async -> Void) {
        onDamaged = handler
    }

    /// Purge-on-lock: cache emptied, in-flight decrypts cancelled,
    /// reader dropped.
    func purge() {
        for task in inflight.values { task.cancel() }
        inflight = [:]
        cache = [:]
        cacheOrder = []
        cacheCost = 0
        reader = nil
    }

    var debugCacheIsEmpty: Bool {
        cache.isEmpty && inflight.isEmpty && cacheCost == 0
    }

    /// Returns the decoded thumbnail for `item`, from cache or by
    /// decrypt+decode. Coalesces concurrent requests per item.
    func image(for item: MediaItem) async -> UIImage? {
        let key = item.id
        if let hit = cache[key] {
            touch(key)
            return hit
        }
        if let running = inflight[key] {
            return await running.value
        }
        guard let reader else { return nil }
        guard let thumbID = item.thumbnailID, item.thumbnailByteLength > 0 else { return nil }
        let length = item.thumbnailByteLength
        let task = Task<UIImage?, Never> { [onDamaged] in
            do {
                let data = try VaultCoordinator.decryptWhole(
                    fileID: thumbID, length: length, reader: reader)
                if Task.isCancelled { return nil }
                return Self.decode(data: data)
            } catch let error as VaultError {
                switch error {
                case .missingChunk, .authenticationFailed:
                    await onDamaged?(key)
                default:
                    break
                }
                return nil
            } catch {
                return nil
            }
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        // `await` is an actor reentrancy point: purge() (lock) may
        // have run while this decode was in flight. A dropped reader
        // marks that generation dead — never repopulate the purged
        // cache with plaintext (wave-001 claude-code #1 / coderabbit).
        guard reader != nil else { return nil }
        if let image {
            insert(image, for: key)
        }
        return image
    }

    /// Prefetch scheduling (Codex A3): kick decodes for soon-visible
    /// items; each is a normal coalesced request.
    func prefetch(_ items: [MediaItem]) {
        for item in items where cache[item.id] == nil && inflight[item.id] == nil {
            Task { _ = await self.image(for: item) }
        }
    }

    /// Cell-reuse / prefetch cancellation.
    func cancel(_ ids: [FileID]) {
        for id in ids {
            inflight[id]?.cancel()
        }
    }

    // MARK: - bounded LRU

    private func insert(_ image: UIImage, for key: FileID) {
        let cost = Self.cost(of: image)
        // Re-insert must not double-count: subtract the entry being
        // replaced or the ceiling drifts down (wave-001 claude-code #8).
        if let existing = cache.removeValue(forKey: key) {
            cacheCost -= Self.cost(of: existing)
        }
        cache[key] = image
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        cacheCost += cost
        while cacheCost > Self.cacheCostLimit, let oldest = cacheOrder.first {
            if let evicted = cache.removeValue(forKey: oldest) {
                cacheCost -= Self.cost(of: evicted)
            }
            cacheOrder.removeFirst()
        }
    }

    private func touch(_ key: FileID) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 << 20 }
        return cg.bytesPerRow * cg.height
    }

    /// Decode fully into a bitmap sized for grid cells; forces
    /// decompression off the main thread.
    static func decode(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Thumbnailer.thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

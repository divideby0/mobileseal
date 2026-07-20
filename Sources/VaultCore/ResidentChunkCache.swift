import Foundation

/// Memory-pressure signal consumed by `ResidentChunkCache`. VaultCore
/// deliberately never subscribes to live OS notifications (CED-12 A.2:
/// deterministic tests, no `DispatchSource` reliance) — the embedder
/// forwards whatever platform signal it trusts into `setPressure(_:)`
/// or the injected stream.
public enum MemoryPressureEvent: Sendable, Equatable {
    /// The platform reports pressure: the budget halves (never below
    /// the floor). Repeated events keep halving down to the floor.
    case pressure
    /// Pressure recovered: the budget restores to its initial cap.
    case recovery
}

/// Injected residency-budget constants (CED-12 A.2). Defaults are the
/// production caps; tests inject small ones so accounting is provable
/// without megabytes of fixtures.
public struct ResidencyBudgetPolicy: Sendable {
    /// Initial (and post-recovery) budget for cache-owned plaintext.
    public var initialBytes: Int
    /// The pressure floor: halving never goes below this.
    public var floorBytes: Int

    public init(initialBytes: Int = 64 << 20, floorBytes: Int = 16 << 20) {
        precondition(floorBytes > 0 && floorBytes <= initialBytes)
        self.initialBytes = initialBytes
        self.floorBytes = floorBytes
    }
}

/// Point-in-time cache accounting, exposed for tests and the app's
/// custody gates (lock must observe cache bytes == 0).
public struct ResidencyStats: Sendable, Equatable {
    public var residentBytes: Int
    public var reservedBytes: Int
    public var budgetBytes: Int
    public var entryCount: Int
    public var pinnedEntryCount: Int
    public var hits: Int
    public var misses: Int
    public var coalescedWaits: Int
    public var evictions: Int
    public var budgetRefusals: Int
}

/// The product of a cache-miss fetch+decrypt: padded plaintext plus
/// its content (unpadded) length. Move-only so the plaintext has one
/// owner until the cache adopts it.
public struct DecryptedChunk: ~Copyable {
    let bytes: SecureBytes
    let contentLength: Int

    public init(bytes: consuming SecureBytes, contentLength: Int) {
        self.bytes = bytes
        self.contentLength = contentLength
    }
}

/// One resident decrypted chunk. A class so the noncopyable buffer
/// has exactly one home while borrowers share a reference; the
/// `SecureBytes` deinit zeroizes, so dropping the LAST reference IS
/// the zeroization point — eviction drops the cache's reference
/// immediately (eviction only ever touches unpinned entries, so under
/// the pinning protocol eviction zeroizes right then).
/// `@unchecked Sendable`: `bytes` is immutable after init and
/// `pinCount` is mutated only under the cache actor's isolation.
final class ResidentChunk: @unchecked Sendable {
    /// Padded chunk plaintext (`count` == the chunk's padded length).
    let bytes: SecureBytes
    /// Content (unpadded) byte count within `bytes`.
    let contentLength: Int
    /// Actor-guarded borrow count; > 0 exempts the entry from
    /// eviction.
    var pinCount = 0

    init(chunk: consuming DecryptedChunk) {
        self.contentLength = chunk.contentLength
        self.bytes = chunk.bytes
    }

    var cost: Int { bytes.count }
}

/// Custody-bound plaintext chunk cache with a residency budget
/// (CED-12 WS A.2). Keyed by `ChunkAddress` — dedup-shared chunks
/// resolve to one entry regardless of which inventory entry reads
/// them (identical address ⇒ identical sealed bytes ⇒ identical AAD
/// context and plaintext).
///
/// Defined semantics (pinned by `ResidentChunkCacheTests`):
///  - entries are PINNED while borrowed; eviction skips pinned
///    entries;
///  - eviction zeroizes (the entry's `SecureBytes` deinit);
///  - concurrent misses for one address COALESCE into a single
///    fetch+decrypt;
///  - a chunk larger than the current budget, or a miss when every
///    resident byte is pinned/reserved, fails typed
///    (`VaultError.budgetExhausted`) — never blocks;
///  - pressure halves the budget (never below the floor) and evicts
///    down to it; recovery restores the initial cap.
///
/// The budget counts ONLY cache-owned decrypted chunk bytes. Response
/// `Data` handed to AVFoundation, decoded frames, and AVFoundation-
/// internal buffers are documented residuals OUTSIDE it (CED-12
/// honest-boundary rule; the custody gate states the same boundary).
public actor ResidentChunkCache {
    private let policy: ResidencyBudgetPolicy
    private var budget: Int

    private var entries: [ChunkAddress: ResidentChunk] = [:]
    /// LRU order: index 0 is the eviction candidate.
    private var lru: [ChunkAddress] = []
    private var inflight: [ChunkAddress: Task<ResidentChunk, Error>] = [:]
    private var residentBytes = 0
    private var reservedBytes = 0
    /// Bumped by `purge()`: a miss that resolves after a purge must
    /// not repopulate the purged cache (the thumbnail-purge lesson,
    /// wave-001) — its entry is dropped (zeroizing) and the read
    /// fails closed.
    private var generation = 0

    private var hits = 0
    private var misses = 0
    private var coalescedWaits = 0
    private var evictions = 0
    private var budgetRefusals = 0

    public init(
        policy: ResidencyBudgetPolicy = ResidencyBudgetPolicy(),
        pressure: AsyncStream<MemoryPressureEvent>? = nil
    ) {
        self.policy = policy
        self.budget = policy.initialBytes
        if let pressure {
            // The feed holds self weakly: it dies with the stream, or
            // on the first event after the cache deallocates.
            Task { [weak self] in
                for await event in pressure {
                    guard let self else { break }
                    await self.setPressure(event)
                }
            }
        }
    }

    // MARK: - pressure

    /// Applies one pressure event (the deterministic seam tests use
    /// directly; the injected stream forwards here).
    public func setPressure(_ event: MemoryPressureEvent) {
        switch event {
        case .pressure:
            budget = max(policy.floorBytes, budget / 2)
            evictToBudget()
        case .recovery:
            budget = policy.initialBytes
        }
    }

    // MARK: - the one read door

    /// Serves the chunk at `address`, borrowing its resident plaintext
    /// for the duration of `body` (the entry is pinned across the
    /// call). On a miss, `fetchAndDecrypt` produces the padded
    /// plaintext (provider fetch + AEAD open, off this actor);
    /// `cost` must be the padded length so admission control runs
    /// BEFORE the fetch. `body` receives the padded buffer and the
    /// content (unpadded) length.
    public func withChunk<R: Sendable>(
        address: ChunkAddress,
        cost: Int,
        fetchAndDecrypt: @escaping @Sendable () async throws -> sending DecryptedChunk,
        _ body: @Sendable (UnsafeRawBufferPointer, _ contentLength: Int) throws -> R
    ) async throws -> R {
        // Hit: pin, serve, unpin.
        if let entry = entries[address] {
            hits += 1
            touch(address)
            return try borrow(entry, body)
        }

        // Coalesce onto an in-flight miss.
        if let task = inflight[address] {
            coalescedWaits += 1
            let entry = try await waitForFetch(task)
            return try borrow(entry, body)
        }

        // Fresh miss: admission control first — fail typed, never
        // block (oversize, or nothing evictable).
        misses += 1
        guard cost <= budget else {
            budgetRefusals += 1
            throw VaultError.budgetExhausted
        }
        guard makeRoom(for: cost) else {
            budgetRefusals += 1
            throw VaultError.budgetExhausted
        }
        reservedBytes += cost
        let task = Task<ResidentChunk, Error> {
            let chunk = try await fetchAndDecrypt()
            return ResidentChunk(chunk: chunk)
        }
        inflight[address] = task
        let startGeneration = generation

        let entry: ResidentChunk
        do {
            entry = try await task.value
        } catch {
            inflight[address] = nil
            reservedBytes -= cost
            throw error
        }
        inflight[address] = nil
        reservedBytes -= cost
        guard generation == startGeneration else {
            // Purged (locked) while decrypting: never repopulate; the
            // dropped entry zeroizes on scope exit.
            throw VaultError.vaultLocked
        }
        entries[address] = entry
        residentBytes += entry.cost
        lru.append(address)
        return try borrow(entry, body)
    }

    /// Waits on a coalesced fetch; the returned reference keeps the
    /// buffer alive (and the borrow pins it) even if the entry was
    /// evicted while this waiter was suspended.
    private func waitForFetch(_ task: Task<ResidentChunk, Error>) async throws -> ResidentChunk {
        let startGeneration = generation
        let entry = try await task.value
        guard generation == startGeneration else { throw VaultError.vaultLocked }
        return entry
    }

    private func borrow<R>(
        _ entry: ResidentChunk,
        _ body: (UnsafeRawBufferPointer, Int) throws -> R
    ) rethrows -> R {
        entry.pinCount += 1
        defer { entry.pinCount -= 1 }
        return try entry.bytes.withUnsafeBytes { raw in
            try body(raw, entry.contentLength)
        }
    }

    // MARK: - eviction

    /// Evicts unpinned LRU entries until `cost` more bytes fit under
    /// the budget (counting in-flight reservations). Returns false —
    /// without evicting further — when pinned entries + reservations
    /// alone make it impossible.
    private func makeRoom(for cost: Int) -> Bool {
        while residentBytes + reservedBytes + cost > budget {
            guard evictOneUnpinned() else { return false }
        }
        return true
    }

    private func evictToBudget() {
        while residentBytes + reservedBytes > budget {
            guard evictOneUnpinned() else { return }
        }
    }

    /// Removes the least-recently-used unpinned entry. Dropping the
    /// cache's reference zeroizes unless a borrower still holds one —
    /// and borrowers pin, so eviction candidates have none.
    private func evictOneUnpinned() -> Bool {
        guard let index = lru.firstIndex(where: { entries[$0]?.pinCount == 0 }) else {
            return false
        }
        let address = lru.remove(at: index)
        if let entry = entries.removeValue(forKey: address) {
            residentBytes -= entry.cost
            evictions += 1
        }
        return true
    }

    private func touch(_ address: ChunkAddress) {
        if let i = lru.firstIndex(of: address) {
            lru.remove(at: i)
            lru.append(address)
        }
    }

    // MARK: - purge (the lock path)

    /// Drops every entry (zeroizing via deinit) and invalidates every
    /// in-flight miss. Part of the playback lock ordering (CED-12
    /// C.3): requests failed → players released → THIS → custodian
    /// drain. Post-lock observable: `stats.residentBytes == 0`.
    public func purge() {
        generation += 1
        for task in inflight.values { task.cancel() }
        entries.removeAll()
        lru.removeAll()
        residentBytes = 0
    }

    // MARK: - observability

    public var stats: ResidencyStats {
        ResidencyStats(
            residentBytes: residentBytes,
            reservedBytes: reservedBytes,
            budgetBytes: budget,
            entryCount: entries.count,
            pinnedEntryCount: entries.values.filter { $0.pinCount > 0 }.count,
            hits: hits,
            misses: misses,
            coalescedWaits: coalescedWaits,
            evictions: evictions,
            budgetRefusals: budgetRefusals)
    }
}

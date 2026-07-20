import Foundation
import Testing

@testable import VaultCore

/// CED-12 WS A.3 test suites: provider contract (incl. unavailable +
/// address-mismatch), padding-aware range→chunk math, and budget
/// accounting/eviction/pinning under concurrency — all UIKit-free.

// MARK: - fake provider (the seam's second implementation)

/// Fake `SealedChunkProvider` proving the seam with the defined
/// minimal semantics: serves from an in-memory map; a missing chunk
/// throws typed `chunkUnavailable` — no suspension/retry machinery.
final class FakeChunkProvider: SealedChunkProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [ChunkAddress: [UInt8]]
    private var fetches = 0
    /// Optional delay so tests can hold a miss open (coalescing).
    var fetchDelayNanos: UInt64 = 0

    init(objects: [ChunkAddress: [UInt8]] = [:]) {
        self.objects = objects
    }

    /// Seeds from a vault's on-disk CAS.
    convenience init(copyingFrom vault: TestVault) throws {
        var map: [ChunkAddress: [UInt8]] = [:]
        for url in try vault.chunkFiles() {
            let bytes = [UInt8](try Data(contentsOf: url))
            map[ChunkAddress.compute(over: bytes)] = bytes
        }
        self.init(objects: map)
    }

    func remove(_ address: ChunkAddress) {
        lock.lock()
        objects[address] = nil
        lock.unlock()
    }

    /// Replaces the object stored under `address` with corrupt bytes
    /// (the CAS-verification test: filed-under name no longer matches).
    func corrupt(_ address: ChunkAddress) {
        lock.lock()
        if var bytes = objects[address] {
            bytes[bytes.count - 1] ^= 0xFF
            objects[address] = bytes
        }
        lock.unlock()
    }

    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fetches
    }

    private func recordFetch(_ address: ChunkAddress) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        fetches += 1
        return objects[address]
    }

    func fetchChunk(_ address: ChunkAddress) async throws -> [UInt8] {
        if fetchDelayNanos > 0 {
            try await Task.sleep(nanoseconds: fetchDelayNanos)
        }
        guard let bytes = recordFetch(address) else {
            throw VaultError.chunkUnavailable(address, retryable: false)
        }
        return bytes
    }
}

// MARK: - shared scaffolding

extension Optional where Wrapped: ~Copyable {
    /// Moves the wrapped value out, leaving nil (the coordinator's
    /// `take()` pattern, local to these tests).
    fileprivate mutating func take() -> Wrapped? {
        let taken = consume self
        self = nil
        return taken
    }
}

/// One unlocked vault with a multi-chunk file imported, plus a
/// streaming reader over a fresh cache. A class so the move-only
/// session has reference-storage custody with an explicit `lock()`.
/// `@unchecked Sendable`: everything is immutable except `session`,
/// which tests only touch after their concurrency completes.
final class StreamingFixture: @unchecked Sendable {
    let vault: TestVault
    private var session: UnlockSession?
    let gallery: Gallery
    let fileID: FileID
    let media: [UInt8]

    init(chunks: Int, tailBytes: Int = 100, seed: UInt64 = 7) async throws {
        vault = try TestVault()
        try vault.create()
        let s = try vault.unlock()
        gallery = try s.openGallery()
        session = consume s
        media = randomBytes(
            Int(testChunkSize) * (chunks - 1) + tailBytes, seed: seed)
        fileID = try await gallery.importBytes(media, chunkSize: testChunkSize)
    }

    func makeReader(
        provider: (any SealedChunkProvider)? = nil,
        policy: ResidencyBudgetPolicy = ResidencyBudgetPolicy(),
        pressure: AsyncStream<MemoryPressureEvent>? = nil
    ) async throws -> (StreamingReader, ResidentChunkCache) {
        let cache = ResidentChunkCache(policy: policy, pressure: pressure)
        let p = try provider ?? vault.open().makeChunkProvider()
        let reader = await gallery.makeStreamingReader(provider: p, cache: cache)
        return (reader, cache)
    }

    func lock() {
        session.take()?.lock()
    }

    func finish() {
        lock()
        vault.destroy()
    }
}

// MARK: - provider contract

@Suite struct SealedChunkProviderContractTests {
    @Test func localStoreServesAndVerifiesAddresses() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let provider = try fx.vault.open().makeChunkProvider()
        let snapshot = await fx.gallery.snapshot()
        let addresses = try #require(snapshot.files.first).chunkAddresses

        for address in addresses {
            let bytes = try await provider.fetchChunk(address)
            #expect(ChunkAddress.compute(over: bytes) == address)
        }
        fx.finish()
    }

    @Test func missingChunkThrowsTypedUnavailable() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let provider = try fx.vault.open().makeChunkProvider()
        let snapshot = await fx.gallery.snapshot()
        let address = try #require(snapshot.files.first).chunkAddresses[0]
        try FileManager.default.removeItem(at: fx.vault.layout.chunkURL(address))

        await #expect(throws: VaultError.chunkUnavailable(address, retryable: false)) {
            _ = try await provider.fetchChunk(address)
        }
        fx.finish()
    }

    @Test func addressMismatchSurfacesFromLocalStore() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let provider = try fx.vault.open().makeChunkProvider()
        let snapshot = await fx.gallery.snapshot()
        let address = try #require(snapshot.files.first).chunkAddresses[0]
        // Corrupt the stored bytes: the file keeps its CAS name but no
        // longer hashes to it.
        try fx.vault.tamper(fx.vault.layout.chunkURL(address), atOffset: 40)

        do {
            _ = try await provider.fetchChunk(address)
            Issue.record("corrupted chunk served without address check")
        } catch let error as VaultError {
            guard case .addressMismatch(let expected, _) = error else {
                throw error
            }
            #expect(expected == address)
        }
        fx.finish()
    }

    @Test func fakeProviderHonorsTheSameContract() async throws {
        let fx = try await StreamingFixture(chunks: 3)
        let fake = try FakeChunkProvider(copyingFrom: fx.vault)
        let (reader, _) = try await fx.makeReader(provider: fake)

        // Serves the full file identically to the local store.
        let data = try await reader.readRange(
            fileID: fx.fileID, offset: 0, length: fx.media.count)
        #expect([UInt8](data) == fx.media)

        // A chunk the fake cannot produce → typed unavailable, and the
        // reader propagates it (distinguishable from AEAD damage).
        let snapshot = await fx.gallery.snapshot()
        let missing = try #require(snapshot.files.first).chunkAddresses[1]
        fake.remove(missing)
        let (freshReader, _) = try await fx.makeReader(provider: fake)
        await #expect(throws: VaultError.chunkUnavailable(missing, retryable: false)) {
            _ = try await freshReader.readRange(
                fileID: fx.fileID, offset: UInt64(testChunkSize),
                length: 10)
        }
        fx.finish()
    }

    @Test func seamRejectsProviderServingWrongBytes() async throws {
        // The SEAM verifies addresses even when a (buggy/hostile)
        // provider does not: corrupt bytes under a correct key.
        let fx = try await StreamingFixture(chunks: 2)
        let fake = try FakeChunkProvider(copyingFrom: fx.vault)
        let snapshot = await fx.gallery.snapshot()
        let address = try #require(snapshot.files.first).chunkAddresses[0]
        fake.corrupt(address)
        let (reader, _) = try await fx.makeReader(provider: fake)

        do {
            _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: 10)
            Issue.record("wrong bytes crossed the seam undetected")
        } catch let error as VaultError {
            guard case .addressMismatch(let expected, _) = error else { throw error }
            #expect(expected == address)
        }
        fx.finish()
    }
}

// MARK: - range→chunk math

@Suite struct StreamingRangeMathTests {
    @Test func rangesSpanningChunkBoundariesRoundTrip() async throws {
        let fx = try await StreamingFixture(chunks: 5, tailBytes: 4097)
        let (reader, _) = try await fx.makeReader()
        let cs = Int(testChunkSize)
        let total = fx.media.count

        // Boundary-heavy probe set: single bytes at edges, straddles,
        // whole-chunk, tail-crossing, full file.
        let probes: [(Int, Int)] = [
            (0, 1), (cs - 1, 1), (cs - 1, 2), (cs, 1),
            (cs / 2, cs),  // straddles one boundary
            (cs, cs),  // exactly chunk 1
            (cs * 2 - 10, cs * 2 + 20),  // three chunks
            (total - 4097, 4097),  // exactly the tail
            (total - 1, 1),
            (0, total),  // whole file
        ]
        for (offset, length) in probes {
            let data = try await reader.readRange(
                fileID: fx.fileID, offset: UInt64(offset), length: length)
            #expect(
                [UInt8](data) == Array(fx.media[offset..<offset + length]),
                "range (\(offset), \(length)) mismatched")
        }
        fx.finish()
    }

    @Test func rangeReadDecryptsOnlyOverlappingChunks() async throws {
        let fx = try await StreamingFixture(chunks: 6)
        let (reader, _) = try await fx.makeReader()
        let cs = Int(testChunkSize)

        // A range inside chunks 2–3 must decrypt exactly those two.
        _ = try await reader.readRange(
            fileID: fx.fileID, offset: UInt64(cs * 2 + 5), length: cs)
        #expect(reader.decryptCount == 2)
        fx.finish()
    }

    @Test func cachedChunksServeRepeatReadsWithoutDecrypting() async throws {
        let fx = try await StreamingFixture(chunks: 3)
        let (reader, cache) = try await fx.makeReader()
        let cs = Int(testChunkSize)

        _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: cs * 2)
        let after = reader.decryptCount
        #expect(after == 2)
        // Overlapping re-read: all resident, zero new decrypts.
        _ = try await reader.readRange(
            fileID: fx.fileID, offset: 10, length: cs)
        #expect(reader.decryptCount == after)
        let stats = await cache.stats
        #expect(stats.hits >= 1)
        fx.finish()
    }

    @Test func outOfBoundsRangesFailTyped() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let (reader, _) = try await fx.makeReader()
        let total = UInt64(fx.media.count)

        await #expect(throws: VaultError.rangeOutOfBounds) {
            _ = try await reader.readRange(fileID: fx.fileID, offset: total, length: 1)
        }
        await #expect(throws: VaultError.rangeOutOfBounds) {
            _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: 0)
        }
        await #expect(throws: VaultError.rangeOutOfBounds) {
            _ = try await reader.readRange(
                fileID: fx.fileID, offset: total - 1, length: 2)
        }
        // Overflow probe: offset near UInt64.max must throw, not trap.
        await #expect(throws: VaultError.rangeOutOfBounds) {
            _ = try await reader.readRange(
                fileID: fx.fileID, offset: UInt64.max - 1, length: 10)
        }
        fx.finish()
    }

    // NOTE (damage taxonomy, relied on by the app's error mapping):
    // with CAS addressing the streaming path surfaces on-disk tamper
    // as `addressMismatch` AT THE SEAM (bytes no longer hash to the
    // requested name — asserted above), and a consistently-renamed
    // tampered object as `chunkUnavailable` (the inventory still
    // names the original address). A live AEAD `authenticationFailed`
    // through this path is reachable only via the drain race, which
    // remaps to `vaultLocked` (StreamingLockTests). The on-disk
    // tamper matrix for the AEAD tier stays owned by ChunkReader's
    // CorruptionMatrixTests.
}

// MARK: - budget accounting / eviction / pinning

@Suite struct ResidentChunkCacheTests {
    /// Padded cost of one test chunk (full chunks: exactly chunkSize).
    static let chunkCost = Int(testChunkSize)

    @Test func evictionKeepsResidencyUnderBudget() async throws {
        let fx = try await StreamingFixture(chunks: 6)
        // Budget: exactly two chunks resident.
        let policy = ResidencyBudgetPolicy(
            initialBytes: Self.chunkCost * 2, floorBytes: Self.chunkCost)
        let (reader, cache) = try await fx.makeReader(policy: policy)
        let cs = Int(testChunkSize)

        // Touch four chunks sequentially; residency must never exceed
        // two chunks and evictions must have happened.
        for i in 0..<4 {
            _ = try await reader.readRange(
                fileID: fx.fileID, offset: UInt64(cs * i), length: cs)
            let stats = await cache.stats
            #expect(stats.residentBytes <= policy.initialBytes)
        }
        let stats = await cache.stats
        #expect(stats.evictions >= 2)
        #expect(stats.entryCount <= 2)
        fx.finish()
    }

    @Test func lruEvictionPrefersColdEntries() async throws {
        let fx = try await StreamingFixture(chunks: 4)
        let policy = ResidencyBudgetPolicy(
            initialBytes: Self.chunkCost * 2, floorBytes: Self.chunkCost)
        let (reader, _) = try await fx.makeReader(policy: policy)
        let cs = Int(testChunkSize)

        // Load 0, 1 → touch 0 → load 2 (evicts 1, not 0).
        _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: cs)
        _ = try await reader.readRange(fileID: fx.fileID, offset: UInt64(cs), length: cs)
        _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: cs)  // touch 0
        let decryptsBefore = reader.decryptCount
        _ = try await reader.readRange(fileID: fx.fileID, offset: UInt64(cs * 2), length: cs)
        // Chunk 0 must still be resident: re-reading it costs nothing.
        _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: cs)
        #expect(reader.decryptCount == decryptsBefore + 1)  // only chunk 2
        fx.finish()
    }

    @Test func oversizeRequestFailsTypedNotBlocking() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        // Budget smaller than one chunk: every miss is oversize.
        let policy = ResidencyBudgetPolicy(
            initialBytes: Self.chunkCost / 2, floorBytes: Self.chunkCost / 4)
        let (reader, cache) = try await fx.makeReader(policy: policy)

        await #expect(throws: VaultError.budgetExhausted) {
            _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: 16)
        }
        let stats = await cache.stats
        #expect(stats.budgetRefusals == 1)
        #expect(stats.residentBytes == 0)
        fx.finish()
    }

    @Test func concurrentMissesCoalesceIntoOneDecrypt() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let fake = try FakeChunkProvider(copyingFrom: fx.vault)
        fake.fetchDelayNanos = 20_000_000  // 20 ms: hold the miss open
        let (reader, cache) = try await fx.makeReader(provider: fake)

        // Ten concurrent readers of the same chunk.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let data = try await reader.readRange(
                        fileID: fx.fileID, offset: 5, length: 64)
                    return data.count
                }
            }
            for try await n in group { #expect(n == 64) }
        }
        // One fetch+decrypt total; the other nine coalesced onto the
        // in-flight miss or landed as hits after insertion.
        #expect(fake.fetchCount == 1)
        #expect(reader.decryptCount == 1)
        let stats = await cache.stats
        #expect(stats.coalescedWaits + stats.hits == 9)
        fx.finish()
    }

    @Test func concurrentDistinctReadsStayWithinBudget() async throws {
        // 7 ⇒ six FULL chunks + tail, so offsets 0…5 each cover a
        // whole chunk.
        let fx = try await StreamingFixture(chunks: 7)
        let policy = ResidencyBudgetPolicy(
            initialBytes: Self.chunkCost * 3, floorBytes: Self.chunkCost)
        let (reader, cache) = try await fx.makeReader(policy: policy)
        let cs = Int(testChunkSize)

        // Six concurrent single-chunk reads against a three-chunk
        // budget: admission control may refuse some TYPED (fail, never
        // block — the spec'd semantics), but every refusal is
        // `budgetExhausted`, at least a budget's worth succeed, and
        // the accounting invariants hold afterward.
        var succeeded = 0
        var refused = 0
        await withTaskGroup(of: Result<Void, Error>.self) { group in
            for i in 0..<6 {
                group.addTask {
                    do {
                        _ = try await reader.readRange(
                            fileID: fx.fileID, offset: UInt64(cs * i), length: cs)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success: succeeded += 1
                case .failure(let error):
                    refused += 1
                    #expect(error as? VaultError == .budgetExhausted)
                }
            }
        }
        #expect(succeeded >= 3)
        #expect(succeeded + refused == 6)
        let stats = await cache.stats
        #expect(stats.residentBytes <= policy.initialBytes)
        #expect(stats.reservedBytes == 0)
        fx.finish()
    }

    @Test func pressureHalvesToFloorAndRecoveryRestores() async throws {
        let fx = try await StreamingFixture(chunks: 6)
        let policy = ResidencyBudgetPolicy(
            initialBytes: Self.chunkCost * 4, floorBytes: Self.chunkCost)
        let (reader, cache) = try await fx.makeReader(policy: policy)
        let cs = Int(testChunkSize)

        for i in 0..<4 {
            _ = try await reader.readRange(
                fileID: fx.fileID, offset: UInt64(cs * i), length: cs)
        }
        var stats = await cache.stats
        #expect(stats.residentBytes == Self.chunkCost * 4)

        // One pressure event: budget halves, cache evicts down to it.
        await cache.setPressure(.pressure)
        stats = await cache.stats
        #expect(stats.budgetBytes == Self.chunkCost * 2)
        #expect(stats.residentBytes <= Self.chunkCost * 2)

        // Repeated pressure: halving clamps at the floor.
        await cache.setPressure(.pressure)
        await cache.setPressure(.pressure)
        await cache.setPressure(.pressure)
        stats = await cache.stats
        #expect(stats.budgetBytes == policy.floorBytes)

        // Recovery restores the initial cap (resident stays shrunken
        // until new reads warm it back).
        await cache.setPressure(.recovery)
        stats = await cache.stats
        #expect(stats.budgetBytes == policy.initialBytes)

        // Playback continues after shrink: reads still succeed.
        _ = try await reader.readRange(
            fileID: fx.fileID, offset: 0, length: cs * 3)
        fx.finish()
    }

    @Test func injectedPressureStreamDrivesTheBudget() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let (events, continuation) = AsyncStream<MemoryPressureEvent>.makeStream()
        let policy = ResidencyBudgetPolicy(
            initialBytes: Self.chunkCost * 4, floorBytes: Self.chunkCost)
        let (_, cache) = try await fx.makeReader(policy: policy, pressure: events)

        continuation.yield(.pressure)
        continuation.finish()
        // The feed is asynchronous; poll briefly for determinism
        // without a live-notification dependency.
        var budget = policy.initialBytes
        for _ in 0..<100 {
            budget = await cache.stats.budgetBytes
            if budget != policy.initialBytes { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(budget == Self.chunkCost * 2)
        fx.finish()
    }

    @Test func purgeZeroizesAndBlocksRepopulation() async throws {
        let fx = try await StreamingFixture(chunks: 3)
        let fake = try FakeChunkProvider(copyingFrom: fx.vault)
        fake.fetchDelayNanos = 30_000_000
        let (reader, cache) = try await fx.makeReader(provider: fake)
        let cs = Int(testChunkSize)

        // Warm one chunk, then race a purge against an in-flight miss.
        fake.fetchDelayNanos = 0
        _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: cs)
        fake.fetchDelayNanos = 30_000_000
        let inFlight = Task {
            try await reader.readRange(
                fileID: fx.fileID, offset: UInt64(cs), length: cs)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await cache.purge()

        // The in-flight miss must NOT repopulate the purged cache.
        await #expect(throws: (any Error).self) { _ = try await inFlight.value }
        let stats = await cache.stats
        #expect(stats.residentBytes == 0)
        #expect(stats.entryCount == 0)
        fx.finish()
    }
}

// MARK: - lock integration

@Suite struct StreamingLockTests {
    @Test func readsFailClosedAfterLock() async throws {
        let fx = try await StreamingFixture(chunks: 2)
        let (reader, cache) = try await fx.makeReader()
        _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: 100)

        fx.lock()
        await cache.purge()
        await #expect(throws: VaultError.vaultLocked) {
            _ = try await reader.readRange(fileID: fx.fileID, offset: 0, length: 100)
        }
        let stats = await cache.stats
        #expect(stats.residentBytes == 0)
        fx.vault.destroy()
    }
}

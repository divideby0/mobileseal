import Foundation
import Testing

@testable import VaultCore

/// An injectable import source that changes its story between passes —
/// the deterministic seam for the TOCTOU guards (wave-003 cc #2).
private struct ShapeShiftingSource: ChunkSource {
    let passes: [[UInt8]]
    var passIndex = 0
    var offset = 0

    mutating func read(into buffer: borrowing SecureBytes, max: Int) throws -> Int {
        let bytes = passes[min(passIndex, passes.count - 1)]
        let n = min(max, bytes.count - offset)
        guard n > 0 else { return 0 }
        buffer.withUnsafeMutableBytes { raw in
            bytes.withUnsafeBufferPointer { src in
                raw.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: offset), byteCount: n)
            }
        }
        offset += n
        return n
    }

    mutating func rewind() throws {
        offset = 0
        passIndex += 1
    }
}

/// Regression locks for wave-003 findings (reviews/wave-003/INDEX.md).
@Suite struct Wave003RegressionTests {
    /// BLOCKER (claude-code #1 / codex #1): the writer claim is
    /// vault-scoped across sessions — a second unlock() cannot mint a
    /// second writer and silently lose an import.
    @Test func secondUnlockCannotMintSecondWriter() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let s1 = try vault.unlock()
        let g1 = try s1.openGallery()
        let s2 = try vault.unlock()
        #expect(throws: VaultError.galleryAlreadyOpen) {
            _ = try s2.openGallery()
        }
        s2.lock()

        // The claim releases with the owning session's lock; a fresh
        // session can then write, and nothing was lost.
        let idA = try await g1.importBytes(randomBytes(100, seed: 61), chunkSize: testChunkSize)
        s1.lock()
        let s3 = try vault.unlock()
        let g3 = try s3.openGallery()
        let idB = try await g3.importBytes(randomBytes(200, seed: 62), chunkSize: testChunkSize)
        let snapshot = await g3.snapshot()
        #expect(Set(snapshot.files.map(\.fileID)) == [idA, idB], "no import may vanish")
        s3.lock()
    }

    /// codex #2: dropping a session without lock() still revokes the
    /// escaped reader (deinit locks the custodian).
    @Test func droppedSessionRevokesEscapedReader() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        func escapeReader() throws -> (ChunkReader, FileID) {
            let session = try vault.unlock()
            let gallery = try session.openGallery()
            // Import synchronously via bytes on the actor is async;
            // use the session-plane reader over an empty vault instead:
            // import first through a scoped gallery call.
            let reader = session.makeReader()
            _ = gallery  // gallery unused beyond claim; session dies here
            return (reader, FileID())
        }
        let (reader, _) = try escapeReader()
        // The session (and its gallery) went out of scope unlocked —
        // the reader must be revoked, not live forever.
        #expect(throws: VaultError.vaultLocked) {
            _ = try reader.metadata(for: FileID())
        }
    }

    /// wave-002 cc #6 / wave-003 cc #2: the mutation guards themselves.
    @Test func importSourceMutationGuardsFire() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()
        let session = try vault.unlock()
        let gallery = try session.openGallery()

        // Same length, different content between passes → the pass-2
        // sealed-hash comparison must throw.
        var mutated = ShapeShiftingSource(passes: [
            randomBytes(2048, seed: 70),
            randomBytes(2048, seed: 71),
        ])
        await #expect(throws: VaultError.sourceChangedDuringImport) {
            var src = mutated
            _ = try await gallery.importSource(&src, metadata: [], chunkSize: testChunkSize)
        }

        // Shrinking source (short read mid-pass-2) → same typed error.
        var shrunk = ShapeShiftingSource(passes: [
            randomBytes(4096, seed: 72),
            randomBytes(1024, seed: 72),
        ])
        await #expect(throws: VaultError.sourceChangedDuringImport) {
            var src = shrunk
            _ = try await gallery.importSource(&src, metadata: [], chunkSize: testChunkSize)
        }
        _ = consume mutated
        _ = consume shrunk

        // Nothing committed, WAL clean.
        let snapshot = await gallery.snapshot()
        #expect(snapshot.files.isEmpty)
        let wal = (try? FileManager.default.contentsOfDirectory(
            atPath: vault.layout.walDir.path)) ?? []
        #expect(wal.isEmpty)
        session.lock()
    }

    /// codex #7: format v0's sole keyring entry must be epoch 0.
    @Test func nonzeroEpochRejectedInV0() throws {
        var w = WireWriter()
        w.raw(FormatV0.metaMagic)
        w.u16(0)
        w.raw(UUID().wireBytes)
        w.u8(1)
        w.u32(3)
        w.u64(256 * 1024 * 1024)
        w.raw([UInt8](repeating: 1, count: 16))
        w.u16(1)
        w.u32(7)  // nonzero epoch
        w.raw([UInt8](repeating: 0, count: 24))
        w.u16(48)
        w.raw([UInt8](repeating: 0, count: 48))
        #expect(throws: VaultError.boundsViolation(.galleryMeta, field: "epoch")) {
            _ = try GalleryMeta.parse(w.bytes)
        }
    }

    /// claude-code #4: a dedup re-import self-heals a missing chunk
    /// instead of minting a second unreadable entry.
    @Test func dedupReimportSelfHealsMissingChunk() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let media = randomBytes(Int(testChunkSize) * 2 + 10, seed: 80)
        var session = try vault.unlock()
        var gallery = try session.openGallery()
        let idA = try await gallery.importBytes(media, chunkSize: testChunkSize)
        session.lock()

        // Lose a chunk (corruption / partial restore).
        let lost = try vault.chunkFiles()[0]
        try FileManager.default.removeItem(at: lost)

        // Re-import the same bytes: must NOT take the dedup shortcut —
        // the new entry must be fully readable. (Entry A itself stays
        // broken: random per-chunk nonces mean re-sealed chunks land
        // at NEW addresses, so A's lost address cannot be restored
        // without rewriting A — an entry-repair capability for a
        // later leg. The point here is the user's re-import yields a
        // WORKING copy, not a second unreadable entry.)
        session = try vault.unlock()
        gallery = try session.openGallery()
        let idB = try await gallery.importBytes(
            media, metadata: Array("again".utf8), chunkSize: testChunkSize)
        let reader = await gallery.makeReader()
        #expect(try readAll(reader, fileID: idB, length: UInt64(media.count)) == media)
        #expect(throws: VaultError.self) {
            _ = try readAll(reader, fileID: idA, length: UInt64(media.count))
        }
        session.lock()
    }

    /// codex #4: concurrent wrong-password attempts cannot all slip
    /// past the limiter — the unlock sequence is serialized per vault.
    @Test func concurrentGuessesRespectBackoff() async throws {
        let fake = FakeClock()
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create(clock: fake.clock)
        let sealed = try vault.open(clock: fake.clock)

        let outcomes = await withTaskGroup(of: String.self) { group in
            for _ in 0..<9 {
                group.addTask {
                    do {
                        let wrong = try SecureBytes(nfcNormalizedPassword: "wrong")
                        _ = try sealed.unlock(password: wrong)
                        return "unlocked?!"
                    } catch VaultError.dekUnwrapFailed {
                        return "kdf-failure"
                    } catch VaultError.rateLimited {
                        return "limited"
                    } catch {
                        return "other"
                    }
                }
            }
            var all: [String] = []
            for await o in group { all.append(o) }
            return all
        }
        // Serialization means at most 6 attempts reach the KDF (5 free
        // + the one starting the cooldown); the rest are limited.
        let kdfRuns = outcomes.filter { $0 == "kdf-failure" }.count
        let limited = outcomes.filter { $0 == "limited" }.count
        #expect(kdfRuns <= 6, "attempts past the free budget must not reach the KDF")
        #expect(limited >= 3)
        #expect(kdfRuns + limited == 9)

        // The persisted count reflects every admitted attempt.
        let limiter = UnlockRateLimiter(url: vault.layout.throttleURL, clock: fake.clock)
        #expect(limiter.load()?.failureCount == UInt32(kdfRuns))
    }
}

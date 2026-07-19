import Foundation
import Testing

@testable import VaultCore

/// Green gate 5 (Codex B5): drain-on-lock semantics. Concurrent
/// readers during lock() either complete within the drain deadline or
/// fail closed with the typed lock error; the DEK allocation is
/// provably zeroed after drain; no read ever returns plaintext derived
/// from a partially-zeroed key (a zeroed key cannot pass the AEAD tag).
@Suite struct LockRaceTests {
    @Test func concurrentReadersDuringLockCompleteOrFailClosed() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let media = randomBytes(Int(testChunkSize) * 4, seed: 31)
        let session = try vault.unlock()
        let gallery = try session.openGallery()
        let fileID = try await gallery.importBytes(media, chunkSize: testChunkSize)
        let reader = await gallery.makeReader()
        let custodian = session.custodian
        let expected = media

        // Hammer reads from a detached task fleet while this task locks.
        let readTask = Task.detached {
            await withTaskGroup(of: [String].self) { group in
                for worker in 0..<8 {
                    group.addTask {
                        // Read continuously UNTIL the lock is observed
                        // (bounded by a 5 s safety valve), so reads are
                        // guaranteed to be in flight when lock() runs.
                        var outcomes: [String] = []
                        let deadline = Date().addingTimeInterval(5)
                        var i = 0
                        while Date() < deadline {
                            i += 1
                            let offset = UInt64((worker * 977 + i * 13) % (media.count - 4096))
                            do {
                                let ok = try reader.readRange(
                                    fileID: fileID, offset: offset, length: 4096
                                ) { bytes in
                                    bytes.withUnsafeBytes { raw in
                                        Array(raw) == Array(expected[Int(offset)..<Int(offset) + 4096])
                                    }
                                }
                                outcomes.append(ok ? "ok" : "CORRUPT")
                            } catch VaultError.vaultLocked {
                                outcomes.append("locked")
                                break
                            } catch {
                                outcomes.append("unexpected:\(error)")
                                break
                            }
                        }
                        return outcomes
                    }
                }
                var all: [String] = []
                for await chunk in group { all.append(contentsOf: chunk) }
                return all
            }
        }

        // Let readers get going, then lock with the default 500 ms
        // drain deadline (consuming — session is unusable afterwards).
        try? await Task.sleep(for: .milliseconds(20))
        session.lock()
        let results = await readTask.value

        // Every read either succeeded with CORRECT bytes or failed
        // closed with the typed lock error — nothing else.
        #expect(!results.contains("CORRUPT"))
        #expect(!results.contains { $0.hasPrefix("unexpected") })
        #expect(results.contains("locked"), "some reads must observe the lock")

        // The DEK allocation is provably zeroed after drain.
        #expect(custodian.debugKeyIsZeroed)

        // New reads after lock are refused immediately.
        #expect(throws: VaultError.vaultLocked) {
            try reader.readRange(fileID: fileID, offset: 0, length: 16) { _ in () }
        }
        // Mutations after lock are refused too.
        await #expect(throws: VaultError.vaultLocked) {
            _ = try await gallery.importBytes([1, 2, 3], chunkSize: testChunkSize)
        }
    }

    /// The wait half of drain-on-lock (wave-001 claude-code #8): park
    /// a reader INSIDE key custody and prove `lock()` actually blocks
    /// until it finishes — an implementation that zeroed immediately
    /// instead of draining would fail the duration assertion.
    @Test func lockWaitsForParkedInFlightRead() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let session = try vault.unlock()
        let custodian = session.custodian
        let holdSeconds = 0.2

        let parked = Flag()
        let readTask = Task.detached { () -> Bool in
            (try? custodian.withKey { raw -> Bool in
                parked.set()
                Thread.sleep(forTimeInterval: holdSeconds)
                // The key must still be intact for the whole hold.
                return !raw.allSatisfy { $0 == 0 }
            }) ?? false
        }

        while !parked.isSet { try await Task.sleep(for: .milliseconds(1)) }
        let lockStart = Date()
        session.lock(drainDeadline: 1.0)
        let lockDuration = Date().timeIntervalSince(lockStart)

        #expect(lockDuration >= holdSeconds * 0.75, "lock() must wait for the in-flight read")
        #expect(lockDuration < 1.0, "drain completed, not the deadline")
        #expect(custodian.debugKeyIsZeroed)
        let readerSawIntactKey = await readTask.value
        #expect(readerSawIntactKey, "the parked read completed against the intact key")
    }

    /// A lease (actor import path) counts as an in-flight read too.
    @Test func lockWaitsForOutstandingLease() async throws {
        let vault = try TestVault()
        defer { vault.destroy() }
        try vault.create()

        let session = try vault.unlock()
        let custodian = session.custodian
        let lease = try custodian.leaseKey()

        let releaseAfter = 0.15
        Task.detached {
            try? await Task.sleep(for: .seconds(releaseAfter))
            _ = lease  // keep alive until here; deinit releases custody
        }
        let lockStart = Date()
        session.lock(drainDeadline: 1.0)
        let lockDuration = Date().timeIntervalSince(lockStart)
        #expect(lockDuration >= releaseAfter * 0.75, "lock() must wait for the lease")
        #expect(custodian.debugKeyIsZeroed)
    }
}

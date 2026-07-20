import AVFoundation
import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// CED-12 gates 2 (unit halves) + 3: the loader-delegate contract
/// against REAL AVFoundation container parsing (both moov
/// placements), the first-presented-frame observable, playback
/// custody under lock (active-requests == 0, cache-bytes == 0), the
/// custody canary during playback, and the unsupported-vs-damaged
/// taxonomy.
///
/// Residual boundary (stated per the gate): the custody assertions
/// cover the request registry, the residency cache, and the app
/// container's filesystem. AVFoundation-INTERNAL buffers (parsed
/// container state, decoder frames) are ordinary process memory
/// outside the audited set — documented, not hand-waved.
@MainActor
@Suite(.serialized) struct PlaybackCustodyTests {
    /// An unlocked vault with playback custody attached and one video
    /// imported through the real pipeline.
    @MainActor
    struct Fixture {
        let vault: UnlockedVault
        let playback: PlaybackController

        static func create(importing fixtureNames: [String]) async throws -> Fixture {
            let vault = try await UnlockedVault.create()
            let playback = PlaybackController()
            await vault.coordinator.attachPlayback(
                cache: playback.cache, participant: playback)

            var providers: [any MediaProvider] = []
            for name in fixtureNames {
                providers.append(
                    FixtureMediaProvider(fixtureURL: try TestSupport.fixtureURL(name)))
            }
            await vault.coordinator.startImport(providers: providers)
            guard await TestSupport.waitUntil({ vault.sink.lastSummary != nil }) else {
                throw TestError("import never finished")
            }
            guard
                await TestSupport.waitUntil({
                    vault.sink.currentStreamingReader != nil
                        && vault.sink.items.count == fixtureNames.count
                })
            else {
                throw TestError("streaming reader/items never published")
            }
            playback.setReader(vault.sink.currentStreamingReader)
            return Fixture(vault: vault, playback: playback)
        }

        var reader: StreamingReader {
            get throws {
                guard let r = vault.sink.currentStreamingReader else {
                    throw TestError("no streaming reader")
                }
                return r
            }
        }

        func item(named name: String) throws -> MediaItem {
            guard let item = vault.sink.items.first(where: { $0.filename == name }) else {
                throw TestError("item \(name) missing; have \(vault.sink.items.map(\.filename))")
            }
            return item
        }

        func delegate(for item: MediaItem) throws -> VaultResourceLoaderDelegate {
            let r = try reader
            return VaultResourceLoaderDelegate(
                reader: r, fileID: item.id, contentUTI: item.uti,
                contentLength: item.byteLength,
                chunkSize: try r.chunkSize(of: item.id))
        }

        func destroy() async {
            await vault.destroy()
        }
    }

    // MARK: - the loader contract, against real container parsing

    /// Fast-start (leading moov): AVFoundation learns the duration
    /// through OUR loader alone — content info + leading ranges.
    @Test func loaderServesFastStartContainer() async throws {
        let fx = try await Fixture.create(importing: ["video-faststart.mp4"])
        defer { Task { await fx.destroy() } }
        let item = try fx.item(named: "video-faststart.mp4")
        let delegate = try fx.delegate(for: item)

        let duration = try await delegate.makeAsset().load(.duration)
        #expect(abs(duration.seconds - 3.0) < 0.25, "duration \(duration.seconds)")

        // Every accepted request completed or was cancelled by
        // AVFoundation — none leaked.
        #expect(
            await TestSupport.waitUntil { delegate.activeRequestCount == 0 },
            "requests leaked: \(delegate.activeRequestCount)")
        let counters = delegate.counters
        #expect(counters.accepted > 0)
        #expect(counters.finished + counters.cancelled + counters.failed == counters.accepted)
        #expect(!delegate.sawIntegrityFailure)
    }

    /// Tail-moov: the sample tables live at EOF, so parsing REQUIRES
    /// out-of-order/tail-first ranges — the Codex B3 case. The
    /// delegate must serve whatever AVFoundation asks, byte-exact.
    @Test func loaderServesTailMoovContainer() async throws {
        let fx = try await Fixture.create(importing: ["video-tailmoov.mov"])
        defer { Task { await fx.destroy() } }
        let item = try fx.item(named: "video-tailmoov.mov")
        let delegate = try fx.delegate(for: item)

        let duration = try await delegate.makeAsset().load(.duration)
        #expect(abs(duration.seconds - 3.0) < 0.25, "duration \(duration.seconds)")
        #expect(await TestSupport.waitUntil { delegate.activeRequestCount == 0 })
        #expect(!delegate.sawIntegrityFailure)
    }

    // MARK: - frames actually present (the e2e/benchmark observable)

    /// Plays the streamed asset and observes PRESENTED pixel buffers
    /// (`AVPlayerItemVideoOutput`) — at start and after scrubs to
    /// three positions. This is gate 2's "frames presented:
    /// first-pixel-buffer observable" and the benchmark's instrument.
    @Test func framesPresentAtStartAndAfterScrubs() async throws {
        let fx = try await Fixture.create(importing: ["video-tailmoov.mov"])
        defer { Task { await fx.destroy() } }
        let item = try fx.item(named: "video-tailmoov.mov")

        let player = try #require(
            fx.playback.activatePlayer(
                fileID: item.id, uti: item.uti, byteLength: item.byteLength))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        let playerItem = try #require(player.currentItem)
        playerItem.add(output)
        player.isMuted = true
        player.play()

        func nextPresentedFrame(timeout: Duration = .seconds(15)) async -> Bool {
            await TestSupport.waitUntil(timeout: timeout) {
                let t = output.itemTime(forHostTime: CACurrentMediaTime())
                return output.hasNewPixelBuffer(forItemTime: t)
            }
        }
        #expect(await nextPresentedFrame(), "no frame presented after autoplay")

        for position in [2.5, 0.5, 1.5] {
            await playerItem.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            #expect(
                await nextPresentedFrame(),
                "no frame presented after scrub to \(position)s")
        }
        fx.playback.releasePlayer()
    }

    // MARK: - lock ordering + concrete observables (gate 3)

    @Test func lockMidPlaybackZeroesRequestsAndCache() async throws {
        let fx = try await Fixture.create(importing: ["video-faststart.mp4"])
        defer { Task { await fx.destroy() } }
        let item = try fx.item(named: "video-faststart.mp4")
        let reader = try fx.reader

        // Live playback custody: player active, cache warm.
        let player = try #require(
            fx.playback.activatePlayer(
                fileID: item.id, uti: item.uti, byteLength: item.byteLength))
        player.isMuted = true
        player.play()
        _ = await TestSupport.waitUntil {
            await fx.playback.cache.stats.residentBytes > 0
        }

        // The ONE lock path: participant sweep → custodian drain.
        await fx.vault.coordinator.lock()
        #expect(await TestSupport.waitUntil { fx.vault.sink.phase == .locked })

        // Concrete post-lock observables (no hand-waving):
        #expect(fx.playback.debugActiveRequestCount == 0)
        let stats = await fx.playback.cache.stats
        #expect(stats.residentBytes == 0, "cache bytes after lock: \(stats.residentBytes)")
        #expect(fx.playback.player == nil)
        #expect(fx.playback.reader == nil)

        // Readers fail closed after the drain.
        await #expect(throws: VaultError.vaultLocked) {
            _ = try await reader.readRange(fileID: item.id, offset: 0, length: 64)
        }
        // Coordinator children torn down (the CED-11 invariant holds
        // with playback in the tree).
        #expect(await fx.vault.coordinator.debugChildrenAreTornDown())
    }

    // MARK: - custody canary during playback (gate 3)

    /// A canary-marked video (valid trailing `free` box) imported,
    /// STREAMED (frames presented), then scanned for: the canary must
    /// exist nowhere in the app container during or after playback —
    /// the streaming path writes no plaintext temp files.
    @Test func canaryCleanDuringAndAfterPlayback() async throws {
        let canary = Array("MOBILESEAL-CANARY-video-2b8d1f4a-plaintext".utf8)
        // free box: u32 size (BE) ‖ "free" ‖ payload.
        let base = try Data(
            contentsOf: TestSupport.fixtureURL("video-faststart.mp4"))
        var boxed = [UInt8](base)
        let payload = canary
        var size = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: &size) { boxed.append(contentsOf: $0) }
        boxed.append(contentsOf: Array("free".utf8))
        boxed.append(contentsOf: payload)
        let canaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canary-\(UUID().uuidString).mp4")
        try Data(boxed).write(to: canaryURL)
        defer { try? FileManager.default.removeItem(at: canaryURL) }

        let vault = try await UnlockedVault.create()
        defer { Task { await vault.destroy() } }
        let playback = PlaybackController()
        await vault.coordinator.attachPlayback(
            cache: playback.cache, participant: playback)
        await vault.coordinator.startImport(providers: [
            FixtureMediaProvider(fixtureURL: canaryURL)
        ])
        #expect(await TestSupport.waitUntil { vault.sink.lastSummary != nil })
        #expect(vault.sink.lastSummary?.importedCount == 1)
        _ = await TestSupport.waitUntil { vault.sink.currentStreamingReader != nil }
        playback.setReader(vault.sink.currentStreamingReader)
        let item = try #require(vault.sink.items.first)

        let containerBase = vault.container.vaultRoot.deletingLastPathComponent()
        // Clean immediately after import (staging lifecycle over).
        #expect(
            TestSupport.filesContaining(canary, under: containerBase).isEmpty,
            "canary on disk after import")

        // Stream it: frames present while we scan.
        let player = try #require(
            playback.activatePlayer(
                fileID: item.id, uti: item.uti, byteLength: item.byteLength))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        player.currentItem?.add(output)
        player.isMuted = true
        player.play()
        #expect(
            await TestSupport.waitUntil(timeout: .seconds(15)) {
                let t = output.itemTime(forHostTime: CACurrentMediaTime())
                return output.hasNewPixelBuffer(forItemTime: t)
            }, "no frame presented from canary video")

        // DURING playback: no plaintext canary anywhere on disk.
        #expect(
            TestSupport.filesContaining(canary, under: containerBase).isEmpty,
            "canary on disk during playback")

        await vault.coordinator.lock()
        _ = await TestSupport.waitUntil { vault.sink.phase == .locked }
        // AFTER lock: still clean, and playback custody zeroed.
        #expect(
            TestSupport.filesContaining(canary, under: containerBase).isEmpty,
            "canary on disk after lock")
        #expect(playback.debugActiveRequestCount == 0)
        let stats = await playback.cache.stats
        #expect(stats.residentBytes == 0)
    }

    // MARK: - unsupported vs damaged (Codex A6)

    /// The unsupported-codec fixture (valid container, `zzzz` sample
    /// entry) imports as SUCCESS: duration recorded, no poster — and
    /// its playback failure carries NO integrity flag.
    @Test func unsupportedCodecImportsAndFailsCleanly() async throws {
        let fx = try await Fixture.create(importing: ["video-unsupported.mp4"])
        defer { Task { await fx.destroy() } }
        #expect(fx.vault.sink.lastSummary?.importedCount == 1)
        let item = try fx.item(named: "video-unsupported.mp4")
        #expect(item.isVideo)
        #expect((item.durationSeconds ?? 0) > 2, "duration should parse from moov")
        #expect(item.thumbnailID == nil, "unsupported codec cannot yield a poster")

        let delegate = try fx.delegate(for: item)
        let asset = delegate.makeAsset()
        // The container parses THROUGH the loader (duration loads),
        // but no decoder claims the codec: unplayable, cleanly.
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 3.0) < 0.25)
        let playable = try await asset.load(.isPlayable)
        #expect(!playable, "zzzz codec must be unplayable")
        // The loader itself served every byte cleanly: this failure is
        // the DECODER's — distinguishable from vault damage.
        #expect(!delegate.sawIntegrityFailure)
        #expect(await TestSupport.waitUntil { delegate.activeRequestCount == 0 })
    }

    /// On-disk tamper: the streaming path surfaces it as a vault
    /// integrity failure — the damaged-item UX, never "can't play".
    @Test func tamperedChunkSurfacesIntegrityFailure() async throws {
        let fx = try await Fixture.create(importing: ["video-faststart.mp4"])
        defer { Task { await fx.destroy() } }
        let item = try fx.item(named: "video-faststart.mp4")

        // Tamper the video's FIRST chunk on disk (find it via the
        // snapshot's address list).
        let gallery = try #require(await fx.vault.coordinator.debugGallery())
        let snapshot = await gallery.snapshot()
        let entry = try #require(snapshot.files.first { $0.fileID == item.id })
        let galleryDir = try #require(
            fx.vault.container.existingGalleryDirectory())
        let chunkURL =
            galleryDir
            .appendingPathComponent("chunks")
            .appendingPathComponent(entry.chunkAddresses[0].hex)
        var bytes = [UInt8](try Data(contentsOf: chunkURL))
        bytes[bytes.count / 2] ^= 0xFF
        try Data(bytes).write(to: chunkURL)

        let delegate = try fx.delegate(for: item)
        let playerItem = AVPlayerItem(asset: delegate.makeAsset())
        let player = AVPlayer(playerItem: playerItem)
        player.isMuted = true
        player.play()
        #expect(
            await TestSupport.waitUntil(timeout: .seconds(15)) {
                delegate.sawIntegrityFailure
            }, "tampered chunk never surfaced as integrity failure")
    }

    // MARK: - still failure taxonomy (wave-001 codex #4)

    /// The pager's still viewer must not regress DetailView's
    /// integrity UX: integrity errors mark damaged; a transient
    /// vaultLocked never does.
    @Test func stillFailureClassifierMatchesDetailViewGuarantees() {
        let missing = MediaPageViewController.stillFailureState(
            for: .missingChunk(ChunkAddress(bytes: [UInt8](repeating: 7, count: 32))!))
        #expect(missing.damaged)
        #expect(missing.message.contains("missing"))

        let tampered = MediaPageViewController.stillFailureState(
            for: .authenticationFailed(.chunk))
        #expect(tampered.damaged)
        #expect(tampered.message.contains("integrity"))

        let seamTamper = MediaPageViewController.stillFailureState(
            for: .addressMismatch(
                expected: ChunkAddress(bytes: [UInt8](repeating: 1, count: 32))!,
                actual: ChunkAddress(bytes: [UInt8](repeating: 2, count: 32))!))
        #expect(seamTamper.damaged)

        let locked = MediaPageViewController.stillFailureState(for: .vaultLocked)
        #expect(!locked.damaged)
        #expect(locked.message.contains("locked"))
    }

    // MARK: - warm-task discipline (wave-001 convergence)

    /// Neighbor warms are retained and CANCELLED by the next
    /// activation/release/lock — the actual mechanism behind the
    /// generation-token discipline.
    @Test func warmTasksAreTrackedAndSweptByLock() async throws {
        let fx = try await Fixture.create(
            importing: ["video-faststart.mp4", "video-tailmoov.mov"])
        defer { Task { await fx.destroy() } }
        let neighbor = try fx.item(named: "video-tailmoov.mov")

        fx.playback.warmNeighbor(
            fileID: neighbor.id, byteLength: neighbor.byteLength)
        #expect(fx.playback.debugWarmsStarted == 1)

        // Lock sweeps in-flight warms (cancelled or already drained —
        // either way none survive) and the counters stay honest.
        await fx.vault.coordinator.lock()
        #expect(await TestSupport.waitUntil { fx.vault.sink.phase == .locked })
        #expect(fx.playback.debugInFlightWarmCount == 0)
        let stats = await fx.playback.cache.stats
        #expect(stats.residentBytes == 0)
    }

    // MARK: - budget degradation (WS D.3)

    /// Under injected pressure the cache shrinks — and playback KEEPS
    /// DELIVERING FRAMES with the shrunken cache, never crashing.
    @Test func playbackContinuesUnderMemoryPressure() async throws {
        let fx = try await Fixture.create(importing: ["video-tailmoov.mov"])
        defer { Task { await fx.destroy() } }
        let item = try fx.item(named: "video-tailmoov.mov")

        let player = try #require(
            fx.playback.activatePlayer(
                fileID: item.id, uti: item.uti, byteLength: item.byteLength))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        player.currentItem?.add(output)
        player.isMuted = true
        player.play()
        func framePresented() async -> Bool {
            await TestSupport.waitUntil(timeout: .seconds(15)) {
                let t = output.itemTime(forHostTime: CACurrentMediaTime())
                return output.hasNewPixelBuffer(forItemTime: t)
            }
        }
        #expect(await framePresented())

        // Simulated pressure (deterministic seam — no live OS
        // notification): budget halves to the floor, cache evicts.
        let before = await fx.playback.cache.stats
        await fx.playback.cache.setPressure(.pressure)
        await fx.playback.cache.setPressure(.pressure)
        await fx.playback.cache.setPressure(.pressure)
        let shrunken = await fx.playback.cache.stats
        #expect(shrunken.budgetBytes < before.budgetBytes)
        #expect(shrunken.residentBytes <= shrunken.budgetBytes)

        // Frames keep coming after the shrink (scrub forces fresh
        // reads through the smaller budget).
        await player.currentItem?.seek(
            to: CMTime(seconds: 2.0, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        #expect(await framePresented(), "no frames under shrunken budget")

        await fx.playback.cache.setPressure(.recovery)
        let recovered = await fx.playback.cache.stats
        #expect(recovered.budgetBytes == before.budgetBytes)
        fx.playback.releasePlayer()
    }
}

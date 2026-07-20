import AVFoundation
import CoreGraphics
import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// CED-12 WS D — the chunk-profile benchmark, decision-grade (Codex
/// B8). Opt-in (it renders 4×30 s videos and takes minutes):
///
///     xcodebuild test … -only-testing:MobileSealTests/ChunkProfileBenchmarkTests \
///       TEST_RUNNER_MOBILESEAL_BENCH=1
///
/// Matrix: the SAME four source videos (H.264 + HEVC, 30 s, 1280×720
/// @ 30 fps, GOP 60, fast-start AND tail-moov) imported into
/// SEPARATE vaults per chunk profile (4 / 2 / 1 MiB — dedup in one
/// gallery would silently reuse the first profile's chunks).
/// Cold-cache control: every repetition uses a FRESH residency cache
/// and a fresh player/asset, so moov parsing and chunk decrypts all
/// happen inside the measured window. (OS page cache of the
/// encrypted files stays warm across reps — a shared, documented
/// residual across all profiles.)
///
/// Measure: seek-to-first-PRESENTED-frame — from seek+play initiation
/// to the first NEW pixel buffer out of `AVPlayerItemVideoOutput` —
/// 10 repetitions spread across 5 positions, reported as p50/p90.
///
/// PREDECLARED decision rule (GOAL WS D.2, fixed before any numbers
/// existed): keep the 4 MiB default unless p90 cold
/// seek-to-first-frame exceeds 400 ms on the simulator AND the
/// difference to the 2 MiB profile exceeds 25% — then adopt a 2 MiB
/// video profile for NEW imports (per-file property; formats.md
/// already permits it). The decision must hold on the physical
/// iPhone (HITL device run) before RESULT.md records it.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOBILESEAL_BENCH"] == "1"))
struct ChunkProfileBenchmarkTests {
    struct Spec {
        let name: String
        let codec: AVVideoCodecType
        let container: AVFileType
        let fastStart: Bool
    }

    nonisolated static let specs = [
        Spec(name: "bench-h264-faststart.mp4", codec: .h264, container: .mp4, fastStart: true),
        Spec(name: "bench-h264-tailmoov.mov", codec: .h264, container: .mov, fastStart: false),
        Spec(name: "bench-hevc-faststart.mp4", codec: .hevc, container: .mp4, fastStart: true),
        Spec(name: "bench-hevc-tailmoov.mov", codec: .hevc, container: .mov, fastStart: false),
    ]
    nonisolated static let seconds = 30
    nonisolated static let fps = 30
    nonisolated static let profiles: [UInt32] = [4 << 20, 2 << 20, 1 << 20]
    nonisolated static let positions: [Double] = [0.5, 7.5, 14.5, 21.5, 28.5]
    nonisolated static let repsPerVideo = 10  // spread across the 5 positions

    @Test func chunkProfileDecision() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 1. Render the four SOURCE videos once (identical bytes feed
        //    every profile's vault).
        var sources: [(Spec, URL)] = []
        for spec in Self.specs {
            let url = scratch.appendingPathComponent(spec.name)
            try await Self.render(spec, to: url)
            sources.append((spec, url))
        }

        // 2. One SEPARATE vault per profile, all four videos imported
        //    with that profile's chunk size.
        var report: [String: [String: [String: Double]]] = [:]  // profile → video → stats
        var aggregate: [UInt32: [Double]] = [:]

        for profile in Self.profiles {
            let profileLabel = "\(profile >> 20)MiB"
            let vaultDir = scratch.appendingPathComponent(
                "vault-\(profileLabel)", isDirectory: true)
            var password = Array("bench password".utf8)
            let pw = try SecureBytes(consumingAndZeroing: &password)
            let vault = try SealedVault.create(
                at: vaultDir, password: pw,
                kdfParams: KDFParams(opslimit: 1, memlimit: 16 << 20))
            var pw2 = Array("bench password".utf8)
            let session = try vault.unlock(
                password: try SecureBytes(consumingAndZeroing: &pw2))
            let gallery = try session.openGallery()

            var videoIDs: [(Spec, FileID, UInt64, String)] = []
            for (spec, url) in sources {
                let fileID = try await gallery.importFile(at: url, chunkSize: profile)
                let length = try #require(
                    await gallery.snapshot().files.first { $0.fileID == fileID }?
                        .unpaddedLength)
                let uti =
                    spec.container == .mp4 ? "public.mpeg-4" : "com.apple.quicktime-movie"
                videoIDs.append((spec, fileID, length, uti))
            }

            var perVideo: [String: [String: Double]] = [:]
            for (spec, fileID, length, uti) in videoIDs {
                var samples: [Double] = []
                for rep in 0..<Self.repsPerVideo {
                    let position = Self.positions[rep % Self.positions.count]
                    let ms = try await Self.coldSeekToFirstFrame(
                        vault: vault, gallery: gallery, fileID: fileID,
                        length: length, uti: uti, position: position)
                    samples.append(ms)
                }
                let stats = Self.percentiles(samples)
                perVideo[spec.name] = ["p50": stats.p50, "p90": stats.p90]
                aggregate[profile, default: []].append(contentsOf: samples)
                print(
                    "BENCH \(profileLabel) \(spec.name): "
                        + "p50=\(Int(stats.p50))ms p90=\(Int(stats.p90))ms")
            }
            report[profileLabel] = perVideo
            session.lock()
        }

        // 3. The predeclared rule, applied mechanically.
        let p90_4 = Self.percentiles(aggregate[4 << 20] ?? []).p90
        let p90_2 = Self.percentiles(aggregate[2 << 20] ?? []).p90
        let p90_1 = Self.percentiles(aggregate[1 << 20] ?? []).p90
        let improvement = p90_4 > 0 ? (p90_4 - p90_2) / p90_4 : 0
        let adoptTwoMiB = p90_4 > 400 && improvement > 0.25
        let decision = adoptTwoMiB ? "adopt-2MiB-video-profile" : "keep-4MiB-default"

        struct BenchResult: Encodable {
            let decision: String
            let p90ByProfileMs: [String: Double]
            let improvementOver4MiB: Double
            let perProfile: [String: [String: [String: Double]]]
        }
        let json = try JSONEncoder().encode(
            BenchResult(
                decision: decision,
                p90ByProfileMs: ["4MiB": p90_4, "2MiB": p90_2, "1MiB": p90_1],
                improvementOver4MiB: improvement,
                perProfile: report))
        print("CHUNK-PROFILE-BENCH \(String(decoding: json, as: UTF8.self))")

        // The gate asserts the harness produced decision-grade data,
        // not a particular outcome.
        #expect((aggregate[4 << 20]?.count ?? 0) == Self.specs.count * Self.repsPerVideo)
        #expect((aggregate[2 << 20]?.count ?? 0) == Self.specs.count * Self.repsPerVideo)
        #expect((aggregate[1 << 20]?.count ?? 0) == Self.specs.count * Self.repsPerVideo)
    }

    /// One COLD repetition: fresh cache, fresh reader, fresh
    /// delegate/asset/player; measure seek+play → first presented
    /// pixel buffer.
    private static func coldSeekToFirstFrame(
        vault: SealedVault, gallery: Gallery, fileID: FileID,
        length: UInt64, uti: String, position: Double
    ) async throws -> Double {
        let cache = ResidentChunkCache()
        let reader = await gallery.makeStreamingReader(
            provider: vault.makeChunkProvider(), cache: cache)
        let delegate = VaultResourceLoaderDelegate(
            reader: reader, fileID: fileID, contentUTI: uti,
            contentLength: length, chunkSize: try reader.chunkSize(of: fileID))
        let item = AVPlayerItem(asset: delegate.makeAsset())
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let start = ContinuousClock.now
        _ = await item.seek(
            to: CMTime(seconds: position, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let deadline = start.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let t = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: t) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        player.pause()
        player.replaceCurrentItem(with: nil)
        await cache.purge()
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return ms
    }

    private static func percentiles(_ samples: [Double]) -> (p50: Double, p90: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double {
            let idx = Int((Double(sorted.count - 1) * q).rounded())
            return sorted[idx]
        }
        return (at(0.5), at(0.9))
    }

    // MARK: - deterministic source rendering (mirrors
    // Scripts/generate-video-fixtures.swift --benchmark)

    private nonisolated static func render(_ spec: Spec, to url: URL) async throws {
        let width = 1280
        let height = 720
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.container)
        writer.shouldOptimizeForNetworkUse = spec.fastStart
        let settings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: spec.codec == .hevc ? 1_500_000 : 2_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw TestError("startWriting: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)
        let frames = seconds * fps
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw TestError("no pool") }
            var maybeBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
            guard let buffer = maybeBuffer else { throw TestError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            let t = CGFloat(frame) / CGFloat(max(frames - 1, 1))
            ctx.setFillColor(CGColor(red: t, green: 0.2, blue: 1 - t, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let barX = CGFloat(frame % fps) / CGFloat(fps) * CGFloat(width - width / 8)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(
                CGRect(
                    x: barX, y: CGFloat(height) * 0.4,
                    width: CGFloat(width) / 8, height: CGFloat(height) * 0.2))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw TestError("append failed: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
        guard writer.status == .completed else {
            throw TestError("finishWriting: \(String(describing: writer.error))")
        }
    }
}

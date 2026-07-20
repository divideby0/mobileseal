#!/usr/bin/env swift
// Video fixture generator (CED-12 WS B.2 / D.1). Deterministic
// synthetic content — a moving bar + per-frame tick marks over a hue
// ramp — rendered through AVAssetWriter so every fixture is
// re-creatable from this script alone (no binary provenance).
//
// e2e set (small, committed under App/Fixtures/):
//   swift Scripts/generate-video-fixtures.swift App/Fixtures
//     video-faststart.mp4   H.264 MP4, moov LEADING (network-optimized)
//     video-tailmoov.mov    H.264 QuickTime MOV, moov TRAILING
//     video-unsupported.mp4 fast-start clone with the stsd sample-
//                           entry FourCC patched to 'zzzz' — a VALID
//                           container iOS cannot decode (Codex A6:
//                           loader failure ≠ AEAD damage)
//     video-paired.mov      tiny MOV standing in for a Live Photo
//                           paired video in fixture imports
//
// benchmark set (large, generated on demand — never committed):
//   swift Scripts/generate-video-fixtures.swift <outdir> --benchmark
//     bench-h264-faststart.mp4 / bench-h264-tailmoov.mov
//     bench-hevc-faststart.mp4 / bench-hevc-tailmoov.mov
//   30 s, 1280×720 @ 30 fps, GOP 60 (2 s) — the defined matrix WS D.1
//   names; separate vaults per chunk profile are the bench's job.

import AVFoundation
import CoreGraphics
import Foundation

struct Spec {
    let name: String
    let codec: AVVideoCodecType
    let container: AVFileType
    let width: Int
    let height: Int
    let seconds: Int
    let fps: Int
    let gop: Int
    let bitrate: Int
    let fastStart: Bool
}

func render(_ spec: Spec, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: spec.container)
    writer.shouldOptimizeForNetworkUse = spec.fastStart

    let settings: [String: Any] = [
        AVVideoCodecKey: spec.codec,
        AVVideoWidthKey: spec.width,
        AVVideoHeightKey: spec.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: spec.bitrate,
            AVVideoMaxKeyFrameIntervalKey: spec.gop,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ])
    writer.add(input)
    guard writer.startWriting() else {
        fatalError("startWriting failed: \(String(describing: writer.error))")
    }
    writer.startSession(atSourceTime: .zero)

    let frames = spec.seconds * spec.fps
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let pool = adaptor.pixelBufferPool else { fatalError("no pixel buffer pool") }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let buffer = maybeBuffer else { fatalError("pixel buffer allocation failed") }

        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: spec.width, height: spec.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Hue ramp background: seek positions are visually distinct.
        let t = CGFloat(frame) / CGFloat(max(frames - 1, 1))
        ctx.setFillColor(CGColor(red: t, green: 0.2, blue: 1 - t, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: spec.width, height: spec.height))
        // Moving bar: motion in every GOP keeps the encoder honest.
        let barX = CGFloat(frame % spec.fps) / CGFloat(spec.fps)
            * CGFloat(spec.width - spec.width / 8)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(
            CGRect(
                x: barX, y: CGFloat(spec.height) * 0.4,
                width: CGFloat(spec.width) / 8, height: CGFloat(spec.height) * 0.2))
        // Second tick marks along the bottom.
        let second = frame / spec.fps
        for s in 0...second {
            ctx.fill(
                CGRect(
                    x: CGFloat(s) * 12 + 4, y: 4, width: 8, height: 12))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(spec.fps))
        if !adaptor.append(buffer, withPresentationTime: time) {
            fatalError("append failed at frame \(frame): \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else {
        fatalError("finishWriting failed: \(String(describing: writer.error))")
    }
}

/// Patches the video sample-entry FourCC inside every `stsd` box to
/// 'zzzz': the container stays structurally valid, but no decoder
/// claims the codec — the "unsupported-but-authentic" fixture.
func patchUnsupportedCodec(input: URL, output: URL) throws {
    var bytes = [UInt8](try Data(contentsOf: input))
    let stsd = Array("stsd".utf8)
    let known = [Array("avc1".utf8), Array("hvc1".utf8), Array("hev1".utf8)]
    var patched = 0
    var i = 4
    while i + 24 <= bytes.count {
        if bytes[i] == stsd[0], bytes[i + 1] == stsd[1], bytes[i + 2] == stsd[2],
            bytes[i + 3] == stsd[3]
        {
            // stsd type at i: entry format FourCC sits at i+16
            // (version/flags 4 + entry_count 4 + entry size 4).
            let f = i + 16
            if known.contains(Array(bytes[f..<f + 4])) {
                bytes.replaceSubrange(f..<f + 4, with: Array("zzzz".utf8))
                patched += 1
            }
        }
        i += 1
    }
    guard patched > 0 else { fatalError("no video stsd entry found to patch") }
    try Data(bytes).write(to: output)
    print("  patched \(patched) sample entr\(patched == 1 ? "y" : "ies") → zzzz")
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: generate-video-fixtures.swift <outdir> [--benchmark]")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let benchmark = args.contains("--benchmark")

let specs: [Spec]
if benchmark {
    specs = [
        Spec(
            name: "bench-h264-faststart.mp4", codec: .h264, container: .mp4,
            width: 1280, height: 720, seconds: 30, fps: 30, gop: 60,
            bitrate: 2_000_000, fastStart: true),
        Spec(
            name: "bench-h264-tailmoov.mov", codec: .h264, container: .mov,
            width: 1280, height: 720, seconds: 30, fps: 30, gop: 60,
            bitrate: 2_000_000, fastStart: false),
        Spec(
            name: "bench-hevc-faststart.mp4", codec: .hevc, container: .mp4,
            width: 1280, height: 720, seconds: 30, fps: 30, gop: 60,
            bitrate: 1_500_000, fastStart: true),
        Spec(
            name: "bench-hevc-tailmoov.mov", codec: .hevc, container: .mov,
            width: 1280, height: 720, seconds: 30, fps: 30, gop: 60,
            bitrate: 1_500_000, fastStart: false),
    ]
} else {
    specs = [
        Spec(
            name: "video-faststart.mp4", codec: .h264, container: .mp4,
            width: 320, height: 240, seconds: 3, fps: 30, gop: 30,
            bitrate: 250_000, fastStart: true),
        Spec(
            name: "video-tailmoov.mov", codec: .h264, container: .mov,
            width: 320, height: 240, seconds: 3, fps: 30, gop: 30,
            bitrate: 250_000, fastStart: false),
        Spec(
            name: "video-paired.mov", codec: .h264, container: .mov,
            width: 320, height: 240, seconds: 2, fps: 30, gop: 30,
            bitrate: 250_000, fastStart: true),
    ]
}

for spec in specs {
    let url = outDir.appendingPathComponent(spec.name)
    print("rendering \(spec.name)…")
    try render(spec, to: url)
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("  \(size) bytes")
}

if !benchmark {
    print("rendering video-unsupported.mp4…")
    try patchUnsupportedCodec(
        input: outDir.appendingPathComponent("video-faststart.mp4"),
        output: outDir.appendingPathComponent("video-unsupported.mp4"))
}
print("done.")

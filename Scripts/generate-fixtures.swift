#!/usr/bin/env swift
// Generates the committed fixture batch for gate 2: deterministic
// small images — mixed JPEG/HEIC with EXIF capture dates — plus one
// deliberately corrupt .jpg (garbage bytes) whose import must surface
// the forced per-item failure. Run on macOS:
//
//     swift Scripts/generate-fixtures.swift App/Fixtures 110
//
// Output is committed; the script exists so the batch is reproducible,
// not because it runs in CI.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: generate-fixtures.swift <output-dir> [count]")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let count = args.count >= 3 ? Int(args[2]) ?? 110 : 110
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Deterministic PRNG (splitmix64) so re-running yields identical
/// pixel patterns for a given index.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 1000) / 1000.0 }
}

func drawImage(index: Int, size: Int) -> CGImage {
    var rng = SplitMix64(state: UInt64(index) &* 0x1234_5678_9ABC_DEF1 &+ 42)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(
        CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    for _ in 0..<12 {
        ctx.setFillColor(
            CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 0.85))
        let w = 8 + rng.unit() * CGFloat(size) / 2
        let h = 8 + rng.unit() * CGFloat(size) / 2
        ctx.fill(
            CGRect(
                x: rng.unit() * (CGFloat(size) - w), y: rng.unit() * (CGFloat(size) - h),
                width: w, height: h))
    }
    // Index stripe: binary bars along the top so each image is
    // visually identifiable and byte-unique.
    for bit in 0..<10 {
        let on = (index >> bit) & 1 == 1
        ctx.setFillColor(CGColor(gray: on ? 1.0 : 0.0, alpha: 1))
        ctx.fill(CGRect(x: bit * (size / 10), y: size - 12, width: size / 10 - 2, height: 10))
    }
    return ctx.makeImage()!
}

func write(image: CGImage, to url: URL, uti: UTType, exifDate: String) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, uti.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.7,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: exifDate
        ],
    ]
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("failed to write \(url.path)")
    }
}

let calendar = Calendar(identifier: .gregorian)
var written = 0
for i in 0..<count {
    let image = drawImage(index: i, size: 256)
    // Spread capture dates over 2024–2025, deterministic per index.
    let day = 1 + (i * 7) % 700
    let base = DateComponents(
        calendar: calendar, timeZone: TimeZone(identifier: "UTC"),
        year: 2024, month: 1, day: 1, hour: 12, minute: i % 60
    ).date!
    let date = calendar.date(byAdding: .day, value: day, to: base)!
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let exifDate = formatter.string(from: date)

    let isHEIC = i % 2 == 1
    let name = String(format: "fixture-%04d.%@", i, isHEIC ? "heic" : "jpg")
    write(
        image: image, to: outDir.appendingPathComponent(name),
        uti: isHEIC ? .heic : .jpeg, exifDate: exifDate)
    written += 1
}

// The forced failure (gate 2): valid-looking name, garbage bytes —
// imports byte-exact but fails thumbnail decode.
var garbage = Data()
var rng = SplitMix64(state: 0xDEAD_BEEF)
for _ in 0..<2048 { garbage.append(UInt8(truncatingIfNeeded: rng.next())) }
try garbage.write(to: outDir.appendingPathComponent("corrupt-zz.jpg"))
written += 1

print("wrote \(written) fixtures to \(outDir.path)")

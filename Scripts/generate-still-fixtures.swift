#!/usr/bin/env swift
// Generates the committed still-decode fidelity fixtures (CED-16):
// deterministic HEICs WITH embedded thumbnails (what iPhone cameras
// produce — the container shape that exposed the IfAbsent bug) plus a
// minimal hand-crafted DNG whose classification exercises the RAW
// routing. Run on macOS:
//
//     swift Scripts/generate-still-fixtures.swift App/Fixtures
//
// Output is committed; the script exists so the batch is reproducible,
// not because it runs in CI.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: generate-still-fixtures.swift <output-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - HEICs with embedded thumbnails

func flatImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A corner marker so the encode isn't degenerate flat color.
    ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 8, height: height / 8))
    return ctx.makeImage()!
}

func writeHEIC(width: Int, height: Int, to name: String) throws {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
        dest, flatImage(width: width, height: height),
        [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("HEIC finalize failed for \(name)")
    }
    // Sanity: the embedded thumbnail must exist and be SMALLER than
    // the source — IfAbsent returning it is exactly the CED-16 bug.
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let ifAbsent: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, ifAbsent as CFDictionary)!
    print("\(name): \(width)x\(height), IfAbsent serves \(thumb.width)x\(thumb.height)")
    guard thumb.width < width else {
        fatalError("\(name) has no smaller embedded thumbnail — fixture would not repro")
    }
}

try writeHEIC(width: 6000, height: 4000, to: "still-embedded-6000x4000.heic")
try writeHEIC(width: 1200, height: 800, to: "still-embedded-1200x800.heic")

// MARK: - Minimal DNG (classification-only fixture)

// ImageIO cannot ENCODE DNG, so this is a hand-assembled little-endian
// TIFF whose IFD0 is a small RGB preview strip plus the DNGVersion tag
// (50706) — enough for ImageIO to classify it com.adobe.raw-image with
// a {DNG} properties dictionary. The RAW pipeline refuses to DECODE a
// camera-less synthetic DNG, so tests assert routing, not pixels.
func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
func u32(_ v: UInt32) -> [UInt8] {
    [
        UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 24) & 0xFF),
    ]
}
func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) -> [UInt8] {
    u16(tag) + u16(type) + u32(count) + u32(value)
}

let pw = 432, ph = 288
var pixels = [UInt8]()
pixels.reserveCapacity(pw * ph * 3)
for _ in 0..<(pw * ph) { pixels.append(contentsOf: [51, 128, 204]) }

var dng = [UInt8]()
dng += [0x49, 0x49]  // "II" little-endian
dng += u16(42)
dng += u32(8)  // IFD0 offset

let numEntries: UInt16 = 11
let dataStart: UInt32 = 8 + 2 + UInt32(numEntries) * 12 + 4
let bpsOffset = dataStart  // 3 SHORTs
let stripOffset = dataStart + 6

var ifd = [UInt8]()
ifd += u16(numEntries)
ifd += entry(254, 4, 1, 1)  // NewSubfileType: reduced-resolution preview
ifd += entry(256, 4, 1, UInt32(pw))  // ImageWidth
ifd += entry(257, 4, 1, UInt32(ph))  // ImageLength
ifd += entry(258, 3, 3, bpsOffset)  // BitsPerSample 8,8,8
ifd += entry(259, 3, 1, 1)  // Compression: none
ifd += entry(262, 3, 1, 2)  // Photometric: RGB
ifd += entry(273, 4, 1, stripOffset)  // StripOffsets
ifd += entry(277, 3, 1, 3)  // SamplesPerPixel
ifd += entry(278, 4, 1, UInt32(ph))  // RowsPerStrip
ifd += entry(279, 4, 1, UInt32(pixels.count))  // StripByteCounts
ifd += u16(50706) + u16(1) + u32(4) + [1, 4, 0, 0]  // DNGVersion 1.4.0.0
ifd += u32(0)  // next IFD

dng += ifd
dng += u16(8) + u16(8) + u16(8)
dng += pixels

let dngURL = outDir.appendingPathComponent("still-preview-432x288.dng")
try Data(dng).write(to: dngURL)
let dngSrc = CGImageSourceCreateWithData(Data(dng) as CFData, nil)!
let dngType = CGImageSourceGetType(dngSrc) as String? ?? "nil"
print("still-preview-432x288.dng: type=\(dngType)")
guard dngType == "com.adobe.raw-image" else {
    fatalError("DNG fixture did not classify as RAW")
}

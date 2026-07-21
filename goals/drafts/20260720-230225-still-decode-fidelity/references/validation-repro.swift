import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 1. Make a 6000x4000 image and write a HEIC WITH an embedded thumbnail
//    (what iPhone cameras do).
let w = 6000, h = 4000
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
let big = ctx.makeImage()!
let url = URL(fileURLWithPath: "/private/tmp/claude-502/-Users-openclaw-src-divideby0-mobileseal/00ececdb-4471-4ec2-a290-270a77bdf88a/scratchpad/test-embedded.heic")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, big, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
CGImageDestinationFinalize(dest)

let data = try! Data(contentsOf: url)
let source = CGImageSourceCreateWithData(data as CFData, nil)!

// 2. StillDecoder's EXACT options (IfAbsent — shipped code)
let shipped: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: 4096,
    kCGImageSourceShouldCacheImmediately: true,
]
let a = CGImageSourceCreateThumbnailAtIndex(source, 0, shipped as CFDictionary)!
print("shipped IfAbsent decode: \(a.width)x\(a.height)")

// 3. The proposed fix (Always)
let fixed: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceThumbnailMaxPixelSize: 4096,
    kCGImageSourceShouldCacheImmediately: true,
]
let b = CGImageSourceCreateThumbnailAtIndex(source, 0, fixed as CFDictionary)!
print("fixed Always decode:     \(b.width)x\(b.height)")

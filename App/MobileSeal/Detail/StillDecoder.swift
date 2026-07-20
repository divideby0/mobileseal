import Foundation
import ImageIO
import UIKit

/// Bounded full-res decode for the detail viewer (GOAL WS C.3, Codex
/// A4): an explicit memory ceiling, enforced by ImageIO downsampling —
/// the decoder never inflates a bitmap larger than the ceiling.
/// ProRAW/DNG decodes through its embedded preview at the same bound
/// (video and anything streaming belongs to the Playback leg).
enum StillDecoder {
    /// Decoded-bitmap ceiling: 4096 px long edge ≈ 64 MiB RGBA — one
    /// on-screen still plus transition headroom inside any iPhone
    /// jetsam budget.
    static let maxPixelSize = 4096

    static func decode(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            // IfAbsent (not Always): reuse an embedded preview when
            // the container has one — that IS the ProRAW/DNG path the
            // goal names (wave-001 coderabbit #5's distinction).
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

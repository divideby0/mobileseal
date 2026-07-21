import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

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
        guard
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0, decodeOptions(for: source) as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Normal images regenerate from the full-size image (`Always`):
    /// `IfAbsent` served the container's embedded preview whenever one
    /// existed, and iPhone-camera HEICs always carry one — a 6000×4000
    /// source displayed as its 432×288 thumbnail (CED-16). RAW/DNG is
    /// the one family that SHOULD reuse its embedded preview — the
    /// full decode is a demosaic, and the preview is the platform's
    /// own display path for ProRAW (CED-12 wave-001 coderabbit #5).
    static func decodeOptions(for source: CGImageSource) -> [CFString: Any] {
        let thumbnailOption =
            usesEmbeddedPreview(source)
            ? kCGImageSourceCreateThumbnailFromImageIfAbsent
            : kCGImageSourceCreateThumbnailFromImageAlways
        return [
            thumbnailOption: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
    }

    /// RAW detection: container UTI conforming to `public.camera-raw-
    /// image`, with the per-index RAW/DNG properties dictionaries as a
    /// fallback for containers whose sniffed type is generic.
    static func usesEmbeddedPreview(_ source: CGImageSource) -> Bool {
        if let typeID = CGImageSourceGetType(source) as String?,
            let type = UTType(typeID), type.conforms(to: .rawImage) {
            return true
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return false }
        return properties[kCGImagePropertyRawDictionary] != nil
            || properties[kCGImagePropertyDNGDictionary] != nil
    }
}

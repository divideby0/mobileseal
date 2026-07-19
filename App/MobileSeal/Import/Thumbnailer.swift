import Foundation
import ImageIO
import UniformTypeIdentifiers

/// App-generated encrypted thumbnails (GOAL WS B.3): thumbnails are
/// the ONLY derived artifact — originals stay byte-exact. Decoding is
/// memory-bounded via ImageIO downsampling
/// (`kCGImageSourceCreateThumbnailAtIndex` never inflates the full
/// bitmap for common formats); ProRAW/DNG resolves through its
/// embedded preview the same way.
enum Thumbnailer {
    /// Long-edge pixel size for stored thumbnails: 512 px covers 3-4
    /// grid columns at 3x scale with headroom for the transition zoom.
    static let thumbnailPixelSize = 512

    struct Output: Sendable {
        let bytes: [UInt8]
        let pixelWidth: Int
        let pixelHeight: Int
        /// Source pixel dimensions and EXIF capture date, read from
        /// the same ImageIO source so import touches the file once.
        let sourceWidth: Int?
        let sourceHeight: Int?
        let dateTaken: Date?
    }

    enum ThumbnailError: Error, Equatable {
        /// The source bytes are not decodable image data — the
        /// per-item import failure for corrupt media (gate 2's forced
        /// failure travels through here).
        case undecodable
        case encodingFailed
    }

    /// Generates a JPEG thumbnail (plus source properties) from a
    /// staged plaintext file.
    static func makeThumbnail(from url: URL) throws -> Output {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ThumbnailError.undecodable
        }
        return try makeThumbnail(source: source)
    }

    /// Same, from in-memory bytes (the unlock-time regeneration path —
    /// Codex B2 recovery rule — where the original is decrypted from
    /// the vault, never re-staged to disk).
    static func makeThumbnail(from data: Data) throws -> Output {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ThumbnailError.undecodable
        }
        return try makeThumbnail(source: source)
    }

    private static func makeThumbnail(source: CGImageSource) throws -> Output {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw ThumbnailError.undecodable
        }

        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int
        let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int
        let dateTaken = exifDate(from: properties)

        let out = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw ThumbnailError.encodingFailed
        }
        CGImageDestinationAddImage(
            dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ThumbnailError.encodingFailed
        }
        return Output(
            bytes: [UInt8](out as Data),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            dateTaken: dateTaken)
    }

    /// EXIF `DateTimeOriginal` (with sub-second + offset when present),
    /// falling back to TIFF `DateTime`.
    private static func exifDate(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard
            let stamp = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        else { return nil }
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let zone = TimeZone(identifier: "GMT\(offset)") ?? timeZone(from: offset) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = TimeZone.current
        }
        return formatter.date(from: stamp)
    }

    private static func timeZone(from offset: String) -> TimeZone? {
        // "+05:30" → seconds
        let sign: Int = offset.hasPrefix("-") ? -1 : 1
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }
}

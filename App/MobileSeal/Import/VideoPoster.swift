import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Poster-frame + properties for a staged video (CED-12 WS B.3): one
/// `AVURLAsset` pass at import reads duration, dimensions, and the
/// first presentable frame. Runs against the STAGED plaintext file —
/// the only moment the video legitimately exists as a file; after
/// import, frames come only through the streaming decrypt path.
enum VideoPoster {
    struct Output: Sendable {
        /// JPEG poster bytes (nil when the codec cannot be decoded —
        /// the unsupported-but-authentic case keeps duration and
        /// imports WITHOUT a preview, distinct from damage).
        let posterJPEG: [UInt8]?
        let posterWidth: Int?
        let posterHeight: Int?
        /// Natural (display-transformed) source dimensions.
        let sourceWidth: Int?
        let sourceHeight: Int?
        let durationSeconds: Double
    }

    enum PosterError: Error, Equatable {
        /// The container itself is unreadable — no duration, no
        /// tracks. This is the per-item import FAILURE; an
        /// unsupported codec inside a valid container is NOT this.
        case unreadableContainer
    }

    static func inspect(url: URL) async throws -> Output {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw PosterError.unreadableContainer
        }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds >= 0 else {
            throw PosterError.unreadableContainer
        }

        var sourceWidth: Int?
        var sourceHeight: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize),
                let transform = try? await track.load(.preferredTransform)
            {
                let display = size.applying(transform)
                sourceWidth = Int(abs(display.width))
                sourceHeight = Int(abs(display.height))
            }
        }

        // Poster: best-effort — an unsupported codec yields nil, not
        // an error (Codex A6: valid-but-unplayable ≠ damaged).
        var poster: (bytes: [UInt8], width: Int, height: Int)?
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: Thumbnailer.thumbnailPixelSize, height: Thumbnailer.thumbnailPixelSize)
        if let (cgImage, _) = try? await generator.image(at: .zero),
            let jpeg = encodeJPEG(cgImage)
        {
            poster = (jpeg, cgImage.width, cgImage.height)
        }

        return Output(
            posterJPEG: poster?.bytes,
            posterWidth: poster?.width,
            posterHeight: poster?.height,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            durationSeconds: seconds)
    }

    private static func encodeJPEG(_ image: CGImage) -> [UInt8]? {
        let out = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](out as Data)
    }
}

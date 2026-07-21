import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MobileSeal

/// CED-16 regression: `IfAbsent` served embedded previews as the
/// "full" still — iPhone-camera HEICs always embed one, so a 6000×4000
/// source displayed at 432×288. Normal images must regenerate at the
/// viewer ceiling; RAW/DNG must keep the embedded-preview path.
@Suite struct StillDecoderTests {
    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: TestSupport.fixtureURL(name))
    }

    /// The validated repro: a large HEIC WITH an embedded thumbnail
    /// must decode at the viewer ceiling, not at the thumbnail's size.
    @Test func largeEmbeddedThumbnailHEICDecodesAtCeiling() throws {
        let data = try fixtureData("still-embedded-6000x4000.heic")
        let image = try #require(StillDecoder.decode(data: data))
        let cg = try #require(image.cgImage)
        let longEdge = max(cg.width, cg.height)
        // ≥ the ceiling proves the embedded 432×288 preview was NOT
        // served; == proves the ceiling still bounds the decode.
        #expect(longEdge == StillDecoder.maxPixelSize)
        #expect(min(cg.width, cg.height) > 288)
    }

    /// A small (< ceiling) image decodes at native size — the Always
    /// path never upscales, and never serves the embedded thumbnail.
    @Test func smallEmbeddedThumbnailHEICDecodesNative() throws {
        let data = try fixtureData("still-embedded-1200x800.heic")
        let image = try #require(StillDecoder.decode(data: data))
        let cg = try #require(image.cgImage)
        #expect(cg.width == 1200)
        #expect(cg.height == 800)
    }

    /// DNG-style container routes to the embedded-preview options.
    /// ImageIO refuses to DECODE a synthetic camera-less DNG (and the
    /// simulator has no RAW pipeline), so the fixture asserts the
    /// routing seam: classification + the IfAbsent option choice.
    @Test func dngRoutesToEmbeddedPreviewPath() throws {
        let data = try fixtureData("still-preview-432x288.dng")
        let source = try #require(
            CGImageSourceCreateWithData(data as CFData, nil))
        #expect(StillDecoder.usesEmbeddedPreview(source))
        let options = StillDecoder.decodeOptions(for: source)
        #expect(options[kCGImageSourceCreateThumbnailFromImageIfAbsent] as? Bool == true)
        #expect(options[kCGImageSourceCreateThumbnailFromImageAlways] == nil)
        #expect(options[kCGImageSourceThumbnailMaxPixelSize] as? Int == StillDecoder.maxPixelSize)
    }

    /// The HEIC family must NOT route to the preview path — that
    /// routing mistake is exactly the CED-16 bug.
    @Test func heicRoutesToRegeneratePath() throws {
        let data = try fixtureData("still-embedded-6000x4000.heic")
        let source = try #require(
            CGImageSourceCreateWithData(data as CFData, nil))
        #expect(!StillDecoder.usesEmbeddedPreview(source))
        let options = StillDecoder.decodeOptions(for: source)
        #expect(options[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool == true)
        #expect(options[kCGImageSourceCreateThumbnailFromImageIfAbsent] == nil)
    }

    /// Committed-batch JPEG (no embedded thumbnail) still decodes —
    /// the option flip must not regress plain sources.
    @Test func plainJPEGStillDecodes() throws {
        let data = try fixtureData("fixture-0000.jpg")
        let image = try #require(StillDecoder.decode(data: data))
        #expect(image.cgImage != nil)
    }
}

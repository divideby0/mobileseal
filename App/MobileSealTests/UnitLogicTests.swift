import Foundation
import Testing
import VaultCore

@testable import MobileSeal

@Suite struct MediaMetadataTests {
    @Test func roundTrip() throws {
        var meta = MediaMetadata(kind: .original, importedAt: Date(timeIntervalSince1970: 1000))
        meta.filename = "IMG_0001.HEIC"
        meta.uti = "public.heic"
        meta.contentHash = String(repeating: "ab", count: 32)
        meta.dateTaken = Date(timeIntervalSince1970: 500)
        meta.pixelWidth = 4032
        meta.pixelHeight = 3024
        let decoded = MediaMetadata.decode(try meta.encoded())
        #expect(decoded == meta)
    }

    @Test func futureVersionAndGarbageDecodeToNil() throws {
        var meta = MediaMetadata(kind: .original, importedAt: Date())
        meta.v = MediaMetadata.currentVersion + 1
        #expect(MediaMetadata.decode(try meta.encoded()) == nil)
        #expect(MediaMetadata.decode(Array("junk".utf8)) == nil)
        #expect(MediaMetadata.decode([]) == nil)
    }

    @Test func v1BlobsStillDecode() throws {
        // Schema evolution rule (CED-12 WS B.3): v1 blobs — every
        // pre-CED-12 entry — decode unchanged; the v2 fields read nil.
        var meta = MediaMetadata(kind: .original, importedAt: Date(timeIntervalSince1970: 7))
        meta.v = 1
        let decoded = try #require(MediaMetadata.decode(try meta.encoded()))
        #expect(decoded.v == 1)
        #expect(decoded.durationSeconds == nil)
    }

    @Test func videoKindCarriesDuration() throws {
        var meta = MediaMetadata(kind: .video, importedAt: Date(timeIntervalSince1970: 9))
        meta.durationSeconds = 12.5
        let decoded = try #require(MediaMetadata.decode(try meta.encoded()))
        #expect(decoded.kind == .video)
        #expect(decoded.durationSeconds == 12.5)
    }

    @Test func parentLinkParses() throws {
        let parent = FileID()
        var meta = MediaMetadata(kind: .thumbnail, importedAt: Date())
        meta.parent = parent.description
        let decoded = try #require(MediaMetadata.decode(try meta.encoded()))
        #expect(decoded.parentFileID == parent)
    }
}

@Suite struct MediaIndexSortTests {
    @Test func sortKeyPrefersDateTakenThenImportDate() {
        let older = MediaItem(
            id: FileID(), filename: nil, uti: nil, contentHash: nil,
            dateTaken: Date(timeIntervalSince1970: 100),
            importedAt: Date(timeIntervalSince1970: 5000),
            pixelWidth: nil, pixelHeight: nil, isLivePhotoStill: false)
        let newerNoExif = MediaItem(
            id: FileID(), filename: nil, uti: nil, contentHash: nil,
            dateTaken: nil,
            importedAt: Date(timeIntervalSince1970: 200),
            pixelWidth: nil, pixelHeight: nil, isLivePhotoStill: false)
        #expect(older.sortDate == Date(timeIntervalSince1970: 100))
        #expect(newerNoExif.sortDate == Date(timeIntervalSince1970: 200))
    }

    @Test func duplicateHashLookup() throws {
        var index = MediaIndex()
        var meta = MediaMetadata(kind: .original, importedAt: Date())
        meta.contentHash = "deadbeef"
        index.record(FileID(), metadata: try meta.encoded())
        #expect(index.containsOriginal(contentHash: "deadbeef"))
        #expect(!index.containsOriginal(contentHash: "cafebabe"))
        #expect(index.originalContentHashes() == ["deadbeef"])
        index.purge()
        #expect(index.isEmpty)
        #expect(!index.containsOriginal(contentHash: "deadbeef"))
    }
}

@Suite struct ThumbnailerTests {
    @Test func jpegAndHeicThumbnails() throws {
        for name in ["fixture-0042.jpg", "fixture-0043.heic"] {
            let out = try Thumbnailer.makeThumbnail(from: TestSupport.fixtureURL(name))
            #expect(!out.bytes.isEmpty)
            #expect(out.pixelWidth <= Thumbnailer.thumbnailPixelSize)
            #expect(out.pixelHeight <= Thumbnailer.thumbnailPixelSize)
            #expect(out.sourceWidth == 256)
            #expect(out.sourceHeight == 256)
            // The generator stamps EXIF DateTimeOriginal (UTC).
            #expect(out.dateTaken != nil)
        }
    }

    @Test func corruptBytesThrowUndecodable() throws {
        #expect(throws: Thumbnailer.ThumbnailError.undecodable) {
            _ = try Thumbnailer.makeThumbnail(from: TestSupport.fixtureURL("corrupt-zz.jpg"))
        }
    }

    @Test func decodeFromDataMatchesFileDecode() throws {
        let data = try Data(contentsOf: TestSupport.fixtureURL("fixture-0044.jpg"))
        let out = try Thumbnailer.makeThumbnail(from: data)
        #expect(!out.bytes.isEmpty)
    }
}

@Suite struct KDFCalibratorTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func raisesWithinEnvelopeWhenHeadroomAllows() {
        // MODERATE measures 0.4 s → 384 MiB predicts 0.6 s, 512 MiB
        // predicts 0.8 s — all inside the envelope; ample headroom →
        // the 512 MiB pick verifies at 0.8 s and wins.
        var measured: [String] = []
        let (params, record) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { p, _ in
                measured.append(KDFCalibrator.label(p))
                return 0.4 * Double(p.memlimit) / Double(256 << 20)
            },
            headroom: 4 << 30,
            thermal: .nominal)
        #expect(params == KDFParams(opslimit: 3, memlimit: 512 << 20))
        #expect(record.fallbackReason == nil)
        #expect(measured == ["3ops/256MiB", "3ops/512MiB"])
        #expect(record.medians["3ops/512MiB"] != nil)
    }

    @Test func staysModerateWithoutHeadroom() {
        let (params, record) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { _, _ in 0.3 },
            headroom: 700 << 20,  // < 2 × 384 MiB
            thermal: .nominal)
        #expect(params == KDFCalibrator.moderate)
        #expect(record.chosenMemlimitMiB == 256)
    }

    @Test func unknownHeadroomNeverRaises() {
        let (params, _) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { _, _ in 0.2 },
            headroom: nil,
            thermal: .nominal)
        #expect(params == KDFCalibrator.moderate)
    }

    @Test func thermalPressureFallsBackToModerate() {
        let (params, record) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { _, _ in
                Issue.record("measurement must not run under thermal pressure")
                return 0.3
            },
            headroom: 4 << 30,
            thermal: .serious)
        #expect(params == KDFCalibrator.moderate)
        #expect(record.fallbackReason?.contains("thermal") == true)
    }

    @Test func verificationFailureFallsBack() {
        // Prediction says 512 MiB fits, verification disagrees.
        let (params, record) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { p, _ in p.memlimit == KDFCalibrator.moderate.memlimit ? 0.4 : 1.4 },
            headroom: 4 << 30,
            thermal: .nominal)
        #expect(params == KDFCalibrator.moderate)
        #expect(record.fallbackReason?.contains("exceeds envelope") == true)
    }

    @Test func slowDeviceStaysAtFloor() {
        let (params, record) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { _, _ in 1.3 },
            headroom: 4 << 30,
            thermal: .nominal)
        #expect(params == KDFCalibrator.moderate)
        #expect(record.fallbackReason?.contains("floor stands") == true)
    }

    @Test func measurementErrorFallsBack() {
        struct Boom: Error {}
        let (params, record) = KDFCalibrator.calibrate(
            scratchDir: scratch(),
            measure: { _, _ in throw Boom() },
            headroom: 4 << 30,
            thermal: .nominal)
        #expect(params == KDFCalibrator.moderate)
        #expect(record.fallbackReason?.contains("measurement failed") == true)
    }
}

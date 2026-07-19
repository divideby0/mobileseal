import Foundation
import VaultCore

/// The app-level encrypted metadata blob attached to every vault entry
/// (opaque bytes to VaultCore; AEAD-protected inside the inventory).
///
/// Version 1 schema (JSON): kind + link model per GOAL WS B.3/B.4 —
/// thumbnails and Live Photo videos are ordinary vault entries LINKED
/// to their parent original via `parent`, never a separate cache.
/// Full EXIF (including location) stays inside the original's bytes;
/// encryption is the privacy layer (grill Q4). `dateTaken` is the
/// EXIF-derived capture date lifted out for the unlock-time sort index
/// (WS C.2); `contentHash` (SHA-256 of the plaintext) powers the app's
/// duplicate skip-with-notice (grill Q5).
struct MediaMetadata: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case original
        case thumbnail
        case livePhotoVideo
    }

    var v: Int = 1
    var kind: Kind
    /// Parent original's FileID (thumbnail / livePhotoVideo only).
    var parent: String?
    /// Original filename as suggested by the provider (originals only).
    var filename: String?
    /// Uniform type identifier of the stored bytes.
    var uti: String?
    /// Lowercase hex SHA-256 of the plaintext (originals only).
    var contentHash: String?
    /// EXIF-derived capture date (originals only, when present).
    var dateTaken: Date?
    /// Import wall-clock date.
    var importedAt: Date
    /// Pixel dimensions when known (originals + thumbnails).
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// True on an original that arrived as a Live Photo still.
    var isLivePhotoStill: Bool?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func encoded() throws -> [UInt8] {
        [UInt8](try Self.encoder.encode(self))
    }

    /// Decodes a blob. Returns nil for unparseable or future-versioned
    /// blobs — the caller treats those entries as opaque (visible but
    /// unclassified), never crashes.
    static func decode(_ bytes: [UInt8]) -> MediaMetadata? {
        guard let meta = try? decoder.decode(MediaMetadata.self, from: Data(bytes)) else {
            return nil
        }
        guard meta.v == 1 else { return nil }
        return meta
    }

    var parentFileID: FileID? {
        guard let parent, let uuid = UUID(uuidString: parent) else { return nil }
        return FileID(uuid: uuid)
    }
}

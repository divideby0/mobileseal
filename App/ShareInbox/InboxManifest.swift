import Foundation

/// The versioned inbox manifest (CED-15 WS B.1, Codex B9): one JSON
/// sidecar per staged item, written LAST — its presence IS the commit
/// point. Everything the main app needs to validate and import the
/// item rides here: UTI, byte length, BLAKE2b-256 hash, Live-Photo
/// pairing, dates. `sourceApp` is OPTIONAL by design (Codex A1: no
/// public API reliably exposes the host app to a share extension).
struct InboxManifest: Codable, Sendable, Equatable {
    /// Schema version this writer emits; readers reject anything else
    /// (a future version is not guessed at).
    static let currentSchemaVersion = 1

    enum Pairing: String, Codable, Sendable {
        /// One payload part: a still or an ordinary video.
        case single
        /// Two payload parts: still + paired video from ONE Live
        /// Photo bundle (mirrors PickerMediaProvider's preference
        /// order — never a duplicated still/video pair, Codex B10).
        case livePhoto
    }

    enum PartRole: String, Codable, Sendable {
        case still
        case pairedVideo
        case video
    }

    struct Part: Codable, Sendable, Equatable {
        let role: PartRole
        /// On-disk payload name inside the inbox — ALWAYS
        /// `<itemID>-<index>.payload` (validated on decode; a manifest
        /// pointing anywhere else is malformed by definition).
        let file: String
        /// The provider-suggested original filename, when known.
        let originalFilename: String?
        let uti: String?
        let byteLength: UInt64
        /// Lowercase-hex BLAKE2b-256 of the payload bytes.
        let blake2b256: String
    }

    let schemaVersion: Int
    let itemID: UUID
    let pairing: Pairing
    let committedAt: Date
    /// Optional, best-effort only (Codex A1).
    let sourceApp: String?
    let parts: [Part]

    /// Expected payload filename for part `index` of item `id`.
    static func payloadName(itemID: UUID, index: Int) -> String {
        "\(itemID.uuidString.lowercased())-\(index).payload"
    }

    static func manifestName(itemID: UUID) -> String {
        "\(itemID.uuidString.lowercased()).manifest.json"
    }

    static func claimName(itemID: UUID) -> String {
        "\(itemID.uuidString.lowercased()).claim.json"
    }

    /// Structural validation beyond Codable (Codex B9): version pinned,
    /// parts non-empty and internally consistent, payload names exactly
    /// the canonical pattern (no traversal, no foreign references),
    /// hashes shaped like BLAKE2b-256 hex.
    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw InboxError.malformedManifest("unsupported schema version \(schemaVersion)")
        }
        guard !parts.isEmpty else {
            throw InboxError.malformedManifest("no parts")
        }
        for (index, part) in parts.enumerated() {
            guard part.file == Self.payloadName(itemID: itemID, index: index) else {
                throw InboxError.malformedManifest("part \(index) names foreign file \(part.file)")
            }
            guard part.blake2b256.count == 64,
                part.blake2b256.allSatisfy({ $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
            else {
                throw InboxError.malformedManifest("part \(index) hash is not BLAKE2b-256 hex")
            }
        }
        switch pairing {
        case .single:
            guard parts.count == 1, parts[0].role != .pairedVideo else {
                throw InboxError.malformedManifest("single pairing with \(parts.count) parts")
            }
        case .livePhoto:
            guard parts.count == 2, parts[0].role == .still, parts[1].role == .pairedVideo
            else {
                throw InboxError.malformedManifest("live-photo pairing without still+video")
            }
        }
    }

    static func decode(_ data: Data) throws -> InboxManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: InboxManifest
        do {
            manifest = try decoder.decode(InboxManifest.self, from: data)
        } catch {
            throw InboxError.malformedManifest(String(describing: error))
        }
        try manifest.validate()
        return manifest
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// A main-app claim marker (CED-15 WS B.2): binds one committed item
/// to the gallery whose import took it. Written by the app only —
/// the extension never claims.
struct InboxClaim: Codable, Sendable, Equatable {
    let galleryID: UUID
    let claimedAt: Date
}

/// One quota-expiry notice (Codex A3): recorded when the writer had to
/// expire oldest committed items to stay within bounds; the main app
/// surfaces the count in its next prompt.
struct InboxExpiryNotice: Codable, Sendable, Equatable {
    enum Reason: String, Codable, Sendable {
        case quotaBytes
        case quotaCount
    }

    let itemID: UUID
    let originalFilename: String?
    let expiredAt: Date
    let reason: Reason
}

/// Typed inbox failures (Codex B8/B9): every refusal is a case, never
/// a stranded partial file.
enum InboxError: Error, Equatable, Sendable {
    case containerUnavailable
    case malformedManifest(String)
    case loadFailed(String)
    case copyFailed(String)
    /// Free space below the safety margin for the incoming copy.
    case diskFull(requiredBytes: Int64, availableBytes: Int64)
    /// The single incoming item alone exceeds the inbox quota.
    case quotaExceeded
    case cancelled
}

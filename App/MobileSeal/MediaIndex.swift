import Foundation
import VaultCore

/// One original as the grid presents it: resolved thumbnail link,
/// paired Live Photo video, damage flag. Value type, Sendable — safe
/// to hand to the MainActor store. Carries decrypted metadata FIELDS
/// (dates, names), which is exactly the documented residual class the
/// grill accepted (Q6: ordinary heap + purge-on-lock, same class as
/// decoded pixels); the index as a whole is emptied on lock.
struct MediaItem: Identifiable, Equatable, Sendable {
    let id: FileID
    var filename: String?
    var uti: String?
    var contentHash: String?
    var dateTaken: Date?
    var importedAt: Date
    var pixelWidth: Int?
    var pixelHeight: Int?
    var isLivePhotoStill: Bool
    /// Plaintext byte length of the original (from the structural
    /// snapshot — the reader API needs an explicit length for whole-
    /// file reads).
    var byteLength: UInt64 = 0
    /// Thumbnail entry linked to this original, if one exists.
    var thumbnailID: FileID?
    var thumbnailByteLength: UInt64 = 0
    /// Paired Live Photo video entry, if one exists.
    var livePhotoVideoID: FileID?
    /// Set when reads against this entry surfaced integrity errors
    /// (missingChunk / authenticationFailed) — per-item damaged badge,
    /// never silent (GOAL WS D.5).
    var damaged: Bool = false

    /// Grid sort key (WS C.2): capture date when known, else import
    /// date; newest first.
    var sortDate: Date { dateTaken ?? importedAt }
}

/// The unlock-time in-memory index (WS C.2 — deliberately supersedes
/// intake-spec §6's SwiftData index for this leg): fileID → decoded
/// metadata, plus link resolution. Built from an `InventorySnapshot`
/// + a same-generation reader's metadata accessors; rebuilt
/// incrementally per committed generation; PURGED on lock.
struct MediaIndex: Sendable, Equatable {
    private(set) var records: [FileID: MediaMetadata] = [:]
    /// Entries whose metadata blob failed to decode (foreign/damaged
    /// blob) — surfaced, never silently dropped.
    private(set) var undecodable: Set<FileID> = []
    /// Thumbnails whose parent original is gone (Codex B2 recovery
    /// rule: ignored for display, reported).
    private(set) var orphanThumbnails: Set<FileID> = []
    /// Originals with no linked thumbnail (regeneration candidates).
    private(set) var missingThumbnails: Set<FileID> = []

    func knows(_ fileID: FileID) -> Bool {
        records[fileID] != nil || undecodable.contains(fileID)
    }

    func metadata(for fileID: FileID) -> MediaMetadata? {
        records[fileID]
    }

    /// Content hashes of every known original (duplicate detection).
    func originalContentHashes() -> Set<String> {
        Set(records.values.filter { $0.kind == .original }.compactMap(\.contentHash))
    }

    /// Merges metadata for `fileID` (idempotent).
    mutating func record(_ fileID: FileID, metadata bytes: [UInt8]) {
        if let meta = MediaMetadata.decode(bytes) {
            records[fileID] = meta
        } else {
            undecodable.insert(fileID)
        }
    }

    mutating func purge() {
        self = MediaIndex()
    }

    var isEmpty: Bool { records.isEmpty && undecodable.isEmpty }

    /// True when an original with this plaintext hash already exists
    /// (duplicate skip-with-notice, grill Q5).
    func containsOriginal(contentHash hash: String) -> Bool {
        records.values.contains { $0.kind == .original && $0.contentHash == hash }
    }

    /// Resolves links against the snapshot's live entry set and
    /// returns date-sorted (newest first) grid items. Also refreshes
    /// the orphan/missing-thumbnail report sets.
    mutating func resolvedItems(in snapshot: InventorySnapshot) -> [MediaItem] {
        let live = Set(snapshot.files.map(\.fileID))
        let lengths = Dictionary(
            uniqueKeysWithValues: snapshot.files.map { ($0.fileID, $0.unpaddedLength) })
        var thumbByParent: [FileID: FileID] = [:]
        var videoByParent: [FileID: FileID] = [:]
        var orphans: Set<FileID> = []
        var missing: Set<FileID> = []

        for (id, meta) in records where live.contains(id) {
            guard let parent = meta.parentFileID else { continue }
            let parentLive =
                live.contains(parent) && records[parent]?.kind == .original
            switch meta.kind {
            case .thumbnail:
                if parentLive {
                    thumbByParent[parent] = id
                } else {
                    orphans.insert(id)
                }
            case .livePhotoVideo:
                if parentLive { videoByParent[parent] = id }
            case .original:
                break
            }
        }

        var items: [MediaItem] = []
        for (id, meta) in records where live.contains(id) && meta.kind == .original {
            let thumb = thumbByParent[id]
            if thumb == nil { missing.insert(id) }
            items.append(
                MediaItem(
                    id: id,
                    filename: meta.filename,
                    uti: meta.uti,
                    contentHash: meta.contentHash,
                    dateTaken: meta.dateTaken,
                    importedAt: meta.importedAt,
                    pixelWidth: meta.pixelWidth,
                    pixelHeight: meta.pixelHeight,
                    isLivePhotoStill: meta.isLivePhotoStill ?? false,
                    byteLength: lengths[id] ?? 0,
                    thumbnailID: thumb,
                    thumbnailByteLength: thumb.flatMap { lengths[$0] } ?? 0,
                    livePhotoVideoID: videoByParent[id]))
        }
        orphanThumbnails = orphans
        missingThumbnails = missing
        return items.sorted {
            ($0.sortDate, $0.id.description) > ($1.sortDate, $1.id.description)
        }
    }
}

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
    /// True for an ordinary imported video (CED-12): played through
    /// the streaming path, badged with `durationSeconds` in the grid.
    var isVideo: Bool = false
    /// Duration for the grid badge (videos, v2 metadata). Pre-CED-12
    /// paired Live-Photo videos have none stored; theirs derives
    /// lazily at open (Codex Q7).
    var durationSeconds: Double?
    /// Plaintext byte length of the original (from the structural
    /// snapshot — the reader API needs an explicit length for whole-
    /// file reads).
    var byteLength: UInt64 = 0
    /// Thumbnail entry linked to this original, if one exists.
    var thumbnailID: FileID?
    var thumbnailByteLength: UInt64 = 0
    /// Paired Live Photo video entry, if one exists (+ what the
    /// streaming player needs to open it: length and UTI).
    var livePhotoVideoID: FileID?
    var livePhotoVideoByteLength: UInt64 = 0
    var livePhotoVideoUTI: String?
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

    /// Content hashes of every known top-level entry — originals AND
    /// videos (duplicate detection covers both).
    func originalContentHashes() -> Set<String> {
        Set(
            records.values
                .filter { $0.kind == .original || $0.kind == .video }
                .compactMap(\.contentHash))
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

    /// True when a top-level entry with this plaintext hash already
    /// exists (duplicate skip-with-notice, grill Q5).
    func containsOriginal(contentHash hash: String) -> Bool {
        records.values.contains {
            ($0.kind == .original || $0.kind == .video) && $0.contentHash == hash
        }
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

        // Top-level (grid-visible) kinds: originals and ordinary
        // videos (CED-12). Derived kinds link to either.
        func isTopLevel(_ kind: MediaMetadata.Kind) -> Bool {
            kind == .original || kind == .video
        }

        for (id, meta) in records where live.contains(id) {
            guard let parent = meta.parentFileID else {
                // A derived entry with a missing or unparseable parent
                // link is as orphaned as it gets — report it, never
                // silently drop it (wave-001 claude-code #9).
                if !isTopLevel(meta.kind) { orphans.insert(id) }
                continue
            }
            let parentLive =
                live.contains(parent) && records[parent].map { isTopLevel($0.kind) } == true
            switch meta.kind {
            case .thumbnail:
                if parentLive {
                    thumbByParent[parent] = id
                } else {
                    orphans.insert(id)
                }
            case .livePhotoVideo:
                if parentLive { videoByParent[parent] = id }
            case .original, .video:
                break
            }
        }

        var items: [MediaItem] = []
        for (id, meta) in records where live.contains(id) && isTopLevel(meta.kind) {
            let thumb = thumbByParent[id]
            // Poster-less videos are an accepted steady state (an
            // undecodable-codec poster cannot be regenerated), so
            // only STILLS report as regeneration candidates.
            if thumb == nil && meta.kind == .original { missing.insert(id) }
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
                    isVideo: meta.kind == .video,
                    durationSeconds: meta.durationSeconds,
                    byteLength: lengths[id] ?? 0,
                    thumbnailID: thumb,
                    thumbnailByteLength: thumb.flatMap { lengths[$0] } ?? 0,
                    livePhotoVideoID: videoByParent[id],
                    livePhotoVideoByteLength: videoByParent[id].flatMap { lengths[$0] } ?? 0,
                    livePhotoVideoUTI: videoByParent[id].flatMap { records[$0]?.uti }))
        }
        orphanThumbnails = orphans
        missingThumbnails = missing
        return items.sorted {
            ($0.sortDate, $0.id.description) > ($1.sortDate, $1.id.description)
        }
    }
}

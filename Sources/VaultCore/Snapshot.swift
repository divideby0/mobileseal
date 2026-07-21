import Foundation

/// Immutable, Sendable view of the inventory at one generation.
/// Carries STRUCTURAL references only (Codex B6): no metadata blobs,
/// no dedup hashes, nothing decrypted — so a snapshot that outlives
/// `lock()` reveals nothing lock was meant to revoke. Metadata is
/// served by session-scoped accessors (`Gallery.metadata(for:)`,
/// `ChunkReader.metadata(for:)`), which fail closed after lock.
public struct InventorySnapshot: Sendable, Equatable {
    public struct FileSummary: Sendable, Equatable {
        public let fileID: FileID
        public let unpaddedLength: UInt64
        public let chunkSize: UInt32
        public let chunkCount: UInt64
        public let chunkAddresses: [ChunkAddress]
        public let epoch: UInt32
    }

    public let generation: UInt64
    public let files: [FileSummary]

    init(_ inventory: Inventory) {
        self.init(revision: inventory.generation, entries: inventory.entries)
    }

    /// v1: the LOCAL commit revision (review Q5) plus the effective
    /// (tombstone-applied) entry set.
    init(revision: UInt64, entries: [InventoryEntry]) {
        self.generation = revision
        self.files = entries.map { e in
            FileSummary(
                fileID: e.fileID,
                unpaddedLength: e.unpaddedLength,
                chunkSize: e.chunkSize,
                chunkCount: UInt64(e.chunkAddresses.count),
                chunkAddresses: e.chunkAddresses,
                epoch: e.epoch)
        }
    }
}

/// Result of the sealed-plane address audit. This proves ADDRESS
/// integrity only — bytes hash to the names they are filed under — not
/// AEAD authenticity, which requires the DEK (`verifyAuthenticity()`).
/// An attacker able to replace both blob and filename defeats this
/// tier; it exists to catch corruption and inconsistent naming.
public struct AddressAuditReport: Sendable, Equatable {
    public enum HeadState: Sendable, Equatable {
        /// HEAD parses and its target inventory object exists.
        case valid(ChunkAddress)
        /// HEAD parses but the referenced inventory object is absent.
        case dangling(ChunkAddress)
        case missing
        case corrupt
    }

    public let verifiedChunkObjects: Int
    public let verifiedInventoryObjects: Int
    /// Files whose contents do not hash to their filename.
    public let mismatchedObjects: [String]
    /// Files in CAS directories whose names are not 64-hex addresses.
    public let foreignFiles: [String]
    public let headState: HeadState

    public var isClean: Bool {
        mismatchedObjects.isEmpty && foreignFiles.isEmpty
            && { if case .valid = headState { return true } else { return false } }()
    }
}

/// Result of the session-plane deep verification (AEAD tier).
public struct DeepVerifyReport: Sendable, Equatable {
    public let verifiedFiles: Int
    public let verifiedChunks: Int
    /// Chunk objects present in the CAS but referenced by no entry.
    /// Harmless to reads; listed so callers can surface/GC them later.
    public let orphanChunks: [ChunkAddress]
}

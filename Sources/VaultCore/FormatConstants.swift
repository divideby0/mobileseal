import Foundation

/// Public, documented format constants callers may need (the full
/// normative set lives in docs/formats.md and internal `FormatV0`).
public enum VaultFormat {
    /// Default per-file chunk size (research: chunk-size-for-encrypted-
    /// media-cas — 4 MiB). Recorded per file in the inventory.
    public static let defaultChunkSize: UInt32 = 4 * 1024 * 1024
    /// Allowed chunk-size range and alignment (Codex A8).
    public static let minChunkSize: UInt32 = 64 * 1024
    public static let maxChunkSize: UInt32 = 8 * 1024 * 1024
    /// Tail chunks pad up to a multiple of this boundary (grill Q12).
    public static let paddingBoundary: UInt32 = 64 * 1024
}

/// Normative constants of on-disk format v0. `docs/formats.md` is the
/// cross-platform contract; these values mirror it byte-for-byte and
/// the format-conformance tests parse the committed fixture vault using
/// ONLY the documented constants.
enum FormatV0 {
    static let version: UInt16 = 0

    // 8-byte magics (ASCII).
    static let metaMagic = Array("MSVMETA0".utf8)
    static let chunkMagic = Array("MSVCHNK0".utf8)
    static let inventoryMagic = Array("MSVINVN0".utf8)
    static let headMagic = Array("MSVHEAD0".utf8)

    // Canonical AAD domain-separation prefixes (ASCII, NUL-terminated).
    static let dekWrapAAD = Array("mobileseal.dekwrap.v0\0".utf8)
    static let chunkAAD = Array("mobileseal.chunk.v0\0".utf8)
    static let inventoryAAD = Array("mobileseal.inventory.v0\0".utf8)
    // Dedup-hash domain prefix (Codex A4): keeps the plaintext dedup
    // hash in a different domain from the (unprefixed) object address.
    static let dedupDomain = Array("mobileseal.dedup.v0\0".utf8)

    // Chunk geometry (Codex A8): per-file chunk size recorded in the
    // inventory, bounded and aligned so hostile metadata cannot demand
    // pathological allocations.
    static let paddingBoundary = VaultFormat.paddingBoundary
    static let minChunkSize = VaultFormat.minChunkSize
    static let maxChunkSize = VaultFormat.maxChunkSize
    static let defaultChunkSize = VaultFormat.defaultChunkSize

    // Keyring bounds (today exactly one entry, epoch 0; the parser
    // accepts up to 8 so rotation is a data change, not a format one).
    static let maxKeyringEntries = 8
    static let wrappedDEKLength = CryptoCore.keyBytes + CryptoCore.aeadTagBytes  // 48

    // Inventory bounds.
    static let maxInventoryEntries: UInt32 = 1_000_000
    static let maxMetadataBlobBytes: UInt32 = 1 * 1024 * 1024
    static let maxInventoryObjectBytes = 256 * 1024 * 1024

    // KDF hard bounds (Codex B13) — validated BEFORE any allocation.
    static let minOpslimit: UInt32 = 1
    static let maxOpslimit: UInt32 = 12
    static let minMemlimit: UInt64 = 16 * 1024 * 1024  // 16 MiB
    static let maxMemlimit: UInt64 = 1024 * 1024 * 1024  // 1 GiB

    /// AAD for a wrapped-DEK keyring entry:
    /// prefix ‖ galleryUUID(16) ‖ epoch u32 LE ‖ formatVersion u16 LE
    static func dekWrapAAD(galleryID: UUID, epoch: UInt32) -> [UInt8] {
        var w = WireWriter()
        w.raw(dekWrapAAD)
        w.raw(galleryID.wireBytes)
        w.u32(epoch)
        w.u16(version)
        return w.bytes
    }

    /// AAD for a content chunk (Codex B3):
    /// prefix ‖ galleryUUID(16) ‖ fileID(16) ‖ chunkIndex u64 LE ‖
    /// epoch u32 LE ‖ formatVersion u16 LE
    static func chunkAAD(galleryID: UUID, fileID: FileID, chunkIndex: UInt64, epoch: UInt32) -> [UInt8] {
        var w = WireWriter()
        w.raw(chunkAAD)
        w.raw(galleryID.wireBytes)
        w.raw(fileID.wireBytes)
        w.u64(chunkIndex)
        w.u32(epoch)
        w.u16(version)
        return w.bytes
    }

    /// AAD for an inventory object:
    /// prefix ‖ galleryUUID(16) ‖ epoch u32 LE ‖ formatVersion u16 LE
    static func inventoryAAD(galleryID: UUID, epoch: UInt32) -> [UInt8] {
        var w = WireWriter()
        w.raw(inventoryAAD)
        w.raw(galleryID.wireBytes)
        w.u32(epoch)
        w.u16(version)
        return w.bytes
    }
}

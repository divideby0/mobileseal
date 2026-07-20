import Foundation

/// Normative constants of on-disk format v1 — the signed manifest that
/// supersedes the v0 local inventory (GOAL WS B). `docs/formats.md`
/// §Format v1 is the cross-platform contract; these values mirror it
/// byte-for-byte. Format v0 constants (gallery.meta, chunk objects)
/// remain in force: v1 changes ONLY the manifest object and HEAD.
enum FormatV1 {
    static let version: UInt16 = 1

    // 8-byte magics (ASCII).
    static let manifestMagic = Array("MSVMANF1".utf8)
    static let headMagic = Array("MSVHEAD1".utf8)

    // AEAD AAD domain-separation prefixes (ASCII, NUL-terminated).
    static let manifestAAD = Array("mobileseal.manifest.v1\0".utf8)
    static let headAAD = Array("mobileseal.head.v1\0".utf8)

    // Signing domain separators (ASCII, NUL-terminated) — one per
    // signed object KIND, so a signature over one kind can never be
    // presented as another (review B1).
    static let addEntrySigDomain = Array("mobileseal.sig.add-entry.v1\0".utf8)
    static let tombstoneSigDomain = Array("mobileseal.sig.tombstone.v1\0".utf8)
    static let trustListSigDomain = Array("mobileseal.sig.trust-list.v1\0".utf8)
    static let headSigDomain = Array("mobileseal.sig.head.v1\0".utf8)

    // Domain prefix for the gallery-bound canonical AddEntry digest
    // (tombstone targeting, review B3).
    static let addEntryDigestDomain = Array("mobileseal.digest.add-entry.v1\0".utf8)

    // Bounds (validated before allocation, like every v0 bound).
    static let maxManifestEntries: UInt32 = 1_000_000
    static let maxTombstones: UInt32 = 1_000_000
    static let maxTrustedDevices: UInt32 = 1024
    static let maxDeviceNameBytes = 256
    static let maxManifestObjectBytes = 256 * 1024 * 1024

    /// Signing preamble shared by every signed object: the signature
    /// covers `domain ‖ sig_version u16 ‖ gallery_uuid ‖ payload`, so
    /// every signature is bound to object kind, format version, and
    /// gallery (review B1). The payload itself carries every semantic
    /// field, including epoch where the object has one.
    static func signingBytes(domain: [UInt8], galleryID: UUID, payload: [UInt8]) -> [UInt8] {
        var w = WireWriter()
        w.raw(domain)
        w.u16(version)
        w.raw(galleryID.wireBytes)
        w.raw(payload)
        return w.bytes
    }

    /// AAD for a sealed manifest object:
    /// prefix ‖ galleryUUID(16) ‖ epoch u32 LE ‖ formatVersion u16 LE
    static func manifestAAD(galleryID: UUID, epoch: UInt32) -> [UInt8] {
        var w = WireWriter()
        w.raw(manifestAAD)
        w.raw(galleryID.wireBytes)
        w.u32(epoch)
        w.u16(version)
        return w.bytes
    }

    /// AAD for the sealed HEAD descriptor:
    /// prefix ‖ galleryUUID(16) ‖ epoch u32 LE ‖ formatVersion u16 LE
    static func headAAD(galleryID: UUID, epoch: UInt32) -> [UInt8] {
        var w = WireWriter()
        w.raw(headAAD)
        w.raw(galleryID.wireBytes)
        w.u32(epoch)
        w.u16(version)
        return w.bytes
    }
}

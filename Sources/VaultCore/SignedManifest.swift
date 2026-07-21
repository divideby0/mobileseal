import Foundation

/// One signed manifest entry (GOAL WS B.2): a superset of the v0
/// inventory entry — the whole storage contract rides along verbatim
/// (`file_id`, `aad_file_id`, dedup hash, chunk geometry, metadata) —
/// plus authorship and the migration provenance flag. Entry identity is
/// `file_id` (review Q2).
struct SignedAddEntry: Equatable, Sendable {
    let entry: InventoryEntry
    let authorPublicKey: DevicePublicKey
    /// True for entries re-signed from a v0 inventory during migration.
    /// Participates in the migration equivalence rule (review B8).
    let migratedFromV0: Bool
    let signature: [UInt8]

    var fileID: FileID { entry.fileID }

    // -- canonical codec --

    static func payloadBytes(
        entry: InventoryEntry, author: DevicePublicKey, migratedFromV0: Bool
    ) -> [UInt8] {
        var w = WireWriter()
        w.raw(entry.fileID.wireBytes)
        w.raw(entry.aadFileID.wireBytes)
        w.u32(entry.epoch)
        w.u32(entry.chunkSize)
        w.u64(entry.unpaddedLength)
        w.raw(entry.dedupHash)
        w.u32(UInt32(entry.chunkAddresses.count))
        for a in entry.chunkAddresses { w.raw(a.bytes) }
        w.u32(UInt32(entry.metadata.count))
        w.raw(entry.metadata)
        w.raw(author.bytes)
        w.u8(migratedFromV0 ? 1 : 0)
        return w.bytes
    }

    var payloadBytes: [UInt8] {
        Self.payloadBytes(entry: entry, author: authorPublicKey, migratedFromV0: migratedFromV0)
    }

    /// Signs a fresh entry as `author`.
    static func minted(
        entry: InventoryEntry, author: DeviceIdentity, migratedFromV0: Bool, galleryID: UUID
    ) -> SignedAddEntry {
        let payload = payloadBytes(
            entry: entry, author: author.publicKey, migratedFromV0: migratedFromV0)
        let signature = author.sign(
            FormatV1.signingBytes(
                domain: FormatV1.addEntrySigDomain, galleryID: galleryID, payload: payload))
        return SignedAddEntry(
            entry: entry, authorPublicKey: author.publicKey,
            migratedFromV0: migratedFromV0, signature: signature)
    }

    func serialize(into w: inout WireWriter) {
        w.raw(payloadBytes)
        w.raw(signature)
    }

    /// Structural parse (bounds identical to the v0 entry rules, plus
    /// the new fields). Signature verification is separate.
    static func parse(_ r: inout WireReader) throws -> SignedAddEntry {
        let fileID = FileID(uuid: try UUID(wireBytes: r.take(16)))
        let aadFileID = FileID(uuid: try UUID(wireBytes: r.take(16)))
        let epoch = try r.u32()
        let chunkSize = try r.u32()
        try ChunkGeometry.validate(chunkSize: chunkSize)
        let unpaddedLength = try r.u64()
        guard unpaddedLength <= FormatV0.maxFileBytes else {
            throw VaultError.boundsViolation(.manifest, field: "unpadded_length")
        }
        let dedupHash = Array(try r.take(CryptoCore.hashBytes))
        let chunkCount = try r.u32()
        let expected = ChunkGeometry.chunkCount(
            unpaddedLength: unpaddedLength, chunkSize: chunkSize)
        guard UInt64(chunkCount) == expected else {
            throw VaultError.boundsViolation(.manifest, field: "chunk_count")
        }
        var addresses: [ChunkAddress] = []
        addresses.reserveCapacity(Int(chunkCount))
        for _ in 0..<chunkCount {
            guard let a = ChunkAddress(bytes: Array(try r.take(CryptoCore.hashBytes))) else {
                throw VaultError.truncatedObject(.manifest)
            }
            addresses.append(a)
        }
        let metadataLen = try r.u32()
        guard metadataLen <= FormatV0.maxMetadataBlobBytes else {
            throw VaultError.boundsViolation(.manifest, field: "metadata_length")
        }
        let metadata = Array(try r.take(Int(metadataLen)))
        guard let author = DevicePublicKey(bytes: Array(try r.take(DevicePublicKey.byteCount)))
        else { throw VaultError.truncatedObject(.manifest) }
        let migratedRaw = try r.u8()
        guard migratedRaw <= 1 else {
            throw VaultError.boundsViolation(.manifest, field: "migrated_from_v0")
        }
        let signature = Array(try r.take(DeviceIdentity.signatureBytes))
        return SignedAddEntry(
            entry: InventoryEntry(
                fileID: fileID, aadFileID: aadFileID, epoch: epoch, chunkSize: chunkSize,
                unpaddedLength: unpaddedLength, dedupHash: dedupHash,
                chunkAddresses: addresses, metadata: metadata),
            authorPublicKey: author,
            migratedFromV0: migratedRaw == 1,
            signature: signature)
    }

    func verify(galleryID: UUID) throws {
        let message = FormatV1.signingBytes(
            domain: FormatV1.addEntrySigDomain, galleryID: galleryID, payload: payloadBytes)
        guard DeviceIdentity.verify(
            signature: signature, message: message, publicKey: authorPublicKey)
        else {
            throw VaultError.signatureInvalid(.addEntry)
        }
    }

    /// The gallery-bound canonical digest of this signed entry (review
    /// B3): BLAKE2b-256 over the digest domain ‖ gallery UUID ‖ the
    /// full canonical signed encoding (payload ‖ signature). Tombstones
    /// carry it, when known, alongside the durable `file_id` target.
    func canonicalDigest(galleryID: UUID) -> [UInt8] {
        CryptoCore.blake2b256(
            FormatV1.addEntryDigestDomain + galleryID.wireBytes + payloadBytes + signature)
    }
}

/// A signed deletion marker (GOAL WS B.3): targets the durable
/// `file_id`, plus the gallery-bound canonical digest of the targeted
/// AddEntry when known. Tombstone-before-add is held inert until its
/// target appears; malformed targets are inert and reported.
struct SignedTombstone: Equatable, Sendable {
    let targetFileID: FileID
    /// Canonical digest of the targeted signed AddEntry, when the
    /// author knew it (32 bytes); nil for a target known only by ID.
    let targetDigest: [UInt8]?
    let authorPublicKey: DevicePublicKey
    let signature: [UInt8]

    static func payloadBytes(
        targetFileID: FileID, targetDigest: [UInt8]?, author: DevicePublicKey
    ) -> [UInt8] {
        var w = WireWriter()
        w.raw(targetFileID.wireBytes)
        if let digest = targetDigest {
            w.u8(1)
            w.raw(digest)
        } else {
            w.u8(0)
        }
        w.raw(author.bytes)
        return w.bytes
    }

    var payloadBytes: [UInt8] {
        Self.payloadBytes(
            targetFileID: targetFileID, targetDigest: targetDigest, author: authorPublicKey)
    }

    /// Full canonical stored bytes — also the set-union identity used
    /// by merge (exact-duplicate collapse).
    var storedBytes: [UInt8] { payloadBytes + signature }

    static func minted(
        targetFileID: FileID, targetDigest: [UInt8]?, author: DeviceIdentity, galleryID: UUID
    ) -> SignedTombstone {
        precondition(targetDigest == nil || targetDigest?.count == CryptoCore.hashBytes)
        let payload = payloadBytes(
            targetFileID: targetFileID, targetDigest: targetDigest, author: author.publicKey)
        let signature = author.sign(
            FormatV1.signingBytes(
                domain: FormatV1.tombstoneSigDomain, galleryID: galleryID, payload: payload))
        return SignedTombstone(
            targetFileID: targetFileID, targetDigest: targetDigest,
            authorPublicKey: author.publicKey, signature: signature)
    }

    func serialize(into w: inout WireWriter) {
        w.raw(payloadBytes)
        w.raw(signature)
    }

    static func parse(_ r: inout WireReader) throws -> SignedTombstone {
        let target = FileID(uuid: try UUID(wireBytes: r.take(16)))
        let hasDigest = try r.u8()
        guard hasDigest <= 1 else {
            throw VaultError.boundsViolation(.manifest, field: "tombstone_digest_flag")
        }
        let digest: [UInt8]? =
            hasDigest == 1 ? Array(try r.take(CryptoCore.hashBytes)) : nil
        guard let author = DevicePublicKey(bytes: Array(try r.take(DevicePublicKey.byteCount)))
        else { throw VaultError.truncatedObject(.manifest) }
        let signature = Array(try r.take(DeviceIdentity.signatureBytes))
        return SignedTombstone(
            targetFileID: target, targetDigest: digest,
            authorPublicKey: author, signature: signature)
    }

    func verify(galleryID: UUID) throws {
        let message = FormatV1.signingBytes(
            domain: FormatV1.tombstoneSigDomain, galleryID: galleryID, payload: payloadBytes)
        guard DeviceIdentity.verify(
            signature: signature, message: message, publicKey: authorPublicKey)
        else {
            throw VaultError.signatureInvalid(.tombstone)
        }
    }
}

/// The decrypted CRDT state of a v1 manifest: signed trust list,
/// signed entries (sorted by file ID), signed tombstones (sorted by
/// canonical bytes). The LOCAL commit revision lives beside it in
/// `ManifestObject`, deliberately outside this struct — it is not part
/// of the CRDT (review Q5).
struct ManifestState: Equatable, Sendable {
    var trustList: SignedTrustList
    var entries: [SignedAddEntry]
    var tombstones: [SignedTombstone]

    // MARK: - Effective view (tombstone application, GOAL WS B.4)

    struct EffectiveView: Sendable {
        var visibleEntries: [InventoryEntry]
        /// Tombstones whose target has not appeared yet (held inert)
        /// or whose digest mismatches a non-migrated entry, or whose
        /// author is untrusted — retained, reported, never applied.
        var inertTombstones: [SignedTombstone]
    }

    /// Applies the tombstone validity rule (author-or-owner — in
    /// single-user semantics every trusted device passes; the rule's
    /// full force arrives with sharing): a tombstone suppresses its
    /// target entry iff its author is trusted, the target `file_id` is
    /// present, and its digest (when known) matches the entry's
    /// canonical digest — OR the entry is a migration duplicate, whose
    /// equivalence class spans signers (review B8: a tombstone minted
    /// against one peer's migrated re-signing must still apply after
    /// the class collapses to the other's).
    func effectiveView(galleryID: UUID) -> EffectiveView {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.fileID, $0) })
        var suppressed: Set<FileID> = []
        var inert: [SignedTombstone] = []
        for t in tombstones {
            guard trustList.contains(t.authorPublicKey),
                let target = byID[t.targetFileID]
            else {
                inert.append(t)
                continue
            }
            if let digest = t.targetDigest,
                digest != target.canonicalDigest(galleryID: galleryID),
                !target.migratedFromV0
            {
                inert.append(t)
                continue
            }
            suppressed.insert(t.targetFileID)
        }
        return EffectiveView(
            visibleEntries: entries.filter { !suppressed.contains($0.fileID) }.map(\.entry),
            inertTombstones: inert)
    }

    // MARK: - Merge (GOAL WS B.4)

    /// Set-union merge keyed by entry identity (`file_id`), with the
    /// migration equivalence rule: entries flagged `migrated_from_v0`
    /// with equal (`file_id`, dedup hash) are ONE logical entry
    /// regardless of signer — the class collapses to the deterministic
    /// representative with the smallest canonical digest, so merge is
    /// commutative, associative, and idempotent. A same-`file_id`
    /// collision OUTSIDE the equivalence rule cannot arise from
    /// conforming writers (file IDs are minted once); it still resolves
    /// deterministically (smallest digest) rather than diverging.
    static func mergeEntries(
        _ a: [SignedAddEntry], _ b: [SignedAddEntry], galleryID: UUID
    ) -> [SignedAddEntry] {
        var byID: [FileID: SignedAddEntry] = [:]
        for e in a + b {
            if let existing = byID[e.fileID], existing != e {
                let existingDigest = existing.canonicalDigest(galleryID: galleryID)
                let candidateDigest = e.canonicalDigest(galleryID: galleryID)
                if candidateDigest.lexicographicallyPrecedes(existingDigest) {
                    byID[e.fileID] = e
                }
            } else {
                byID[e.fileID] = e
            }
        }
        return byID.values.sorted {
            $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes)
        }
    }

    /// Tombstone union: exact canonical-bytes identity, sorted.
    static func mergeTombstones(
        _ a: [SignedTombstone], _ b: [SignedTombstone]
    ) -> [SignedTombstone] {
        var seen: Set<[UInt8]> = []
        var out: [SignedTombstone] = []
        for t in a + b where seen.insert(t.storedBytes).inserted {
            out.append(t)
        }
        return out.sorted { $0.storedBytes.lexicographicallyPrecedes($1.storedBytes) }
    }

    /// Content-level merge result: the trust DEVICE SET is the CRDT
    /// element (append-only union); the signed carrier list is minted
    /// by whichever device commits the merged state.
    struct MergedContent: Sendable {
        var devices: [TrustedDevice]
        var maxTrustListVersion: UInt64
        var entries: [SignedAddEntry]
        var tombstones: [SignedTombstone]
    }

    static func mergeContent(
        _ a: ManifestState, _ b: ManifestState, galleryID: UUID
    ) -> MergedContent {
        MergedContent(
            devices: SignedTrustList.mergeDevices(a.trustList.devices, b.trustList.devices),
            maxTrustListVersion: max(a.trustList.listVersion, b.trustList.listVersion),
            entries: mergeEntries(a.entries, b.entries, galleryID: galleryID),
            tombstones: mergeTombstones(a.tombstones, b.tombstones))
    }

    // MARK: - Verification (order: decrypt → parse → verify signatures)

    /// Verifies every signature in the state: the trust list first
    /// (its signer must be self-listed), then every entry and
    /// tombstone. Entry/tombstone AUTHORS need not be in the trust
    /// list for their signatures to verify — authorship trust is the
    /// tombstone-application rule's concern; entries authored by
    /// not-yet-registered devices remain readable (single-user
    /// semantics: possession of the gallery password is authorization).
    func verifySignatures(galleryID: UUID) throws {
        try trustList.verify(galleryID: galleryID)
        for e in entries { try e.verify(galleryID: galleryID) }
        for t in tombstones { try t.verify(galleryID: galleryID) }
    }
}

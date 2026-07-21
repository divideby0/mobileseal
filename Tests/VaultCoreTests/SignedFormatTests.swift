import Foundation
import Testing

@testable import VaultCore

/// Canonical-encoding KATs and signature probes (green gate 1, reviews
/// B1/A1/A2/A3): every signed object accepts exactly ONE
/// representation; wrong gallery, wrong domain, wrong version, and
/// tampered fields each fail AT THE SIGNATURE LAYER, distinguishable
/// from AEAD failure.
@Suite struct SignedFormatTests {
    let galleryID = UUID(uuidString: "a1b2c3d4-0000-4000-8000-000000000001")!
    let otherGalleryID = UUID(uuidString: "a1b2c3d4-0000-4000-8000-000000000002")!

    func makeEntry(_ identity: DeviceIdentity, migrated: Bool = false, seed: UInt64 = 7)
        -> SignedAddEntry
    {
        let entry = InventoryEntry(
            fileID: FileID(), aadFileID: FileID(), epoch: 0, chunkSize: 65536,
            unpaddedLength: 100, dedupHash: randomBytes(32, seed: seed),
            chunkAddresses: [ChunkAddress(bytes: randomBytes(32, seed: seed &+ 1))!],
            metadata: Array("meta".utf8))
        return SignedAddEntry.minted(
            entry: entry, author: identity, migratedFromV0: migrated, galleryID: galleryID)
    }

    func makeState(_ identity: DeviceIdentity) -> ManifestState {
        let trust = SignedTrustList.minted(
            listVersion: 1,
            devices: [
                TrustedDevice(
                    publicKey: identity.publicKey, role: .owner,
                    addedAtUnixMS: 1_700_000_000_000, name: "probe-device")
            ],
            signer: identity, galleryID: galleryID)
        let e = makeEntry(identity)
        let t = SignedTombstone.minted(
            targetFileID: FileID(), targetDigest: nil, author: identity, galleryID: galleryID)
        return ManifestState(trustList: trust, entries: [e], tombstones: [t])
    }

    // MARK: - Canonical encoding: exactly one representation

    @Test func manifestBodyRoundTripsByteIdentically() throws {
        let identity = try DeviceIdentity.generate()
        let object = ManifestObject(localRevision: 42, state: makeState(identity))
        let body = object.serializeBody()
        let reparsed = try ManifestObject.parseBody(body)
        #expect(reparsed == object)
        #expect(reparsed.serializeBody() == body, "one canonical representation")
        try reparsed.state.verifySignatures(galleryID: galleryID)
    }

    @Test func trailingBytesRejected() throws {
        let identity = try DeviceIdentity.generate()
        let body = ManifestObject(localRevision: 1, state: makeState(identity)).serializeBody()
        #expect(throws: VaultError.boundsViolation(.manifest, field: "trailing bytes")) {
            _ = try ManifestObject.parseBody(body + [0])
        }
    }

    @Test func unsortedEntriesRejected() throws {
        let identity = try DeviceIdentity.generate()
        var state = makeState(identity)
        let e2 = makeEntry(identity, seed: 99)
        // Deliberately mis-order: descending by file ID.
        var entries = [state.entries[0], e2].sorted {
            $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes)
        }
        entries.reverse()
        state.entries = entries
        let body = ManifestObject(localRevision: 1, state: state).serializeBody()
        #expect(throws: VaultError.boundsViolation(.manifest, field: "entry_order")) {
            _ = try ManifestObject.parseBody(body)
        }
    }

    @Test func duplicateEntryIdentityRejected() throws {
        let identity = try DeviceIdentity.generate()
        var state = makeState(identity)
        state.entries = [state.entries[0], state.entries[0]]
        let body = ManifestObject(localRevision: 1, state: state).serializeBody()
        // Equal file IDs violate STRICT ascending order.
        #expect(throws: VaultError.boundsViolation(.manifest, field: "entry_order")) {
            _ = try ManifestObject.parseBody(body)
        }
    }

    @Test func duplicateOrUnsortedTombstonesRejected() throws {
        let identity = try DeviceIdentity.generate()
        var state = makeState(identity)
        state.tombstones = [state.tombstones[0], state.tombstones[0]]
        let body = ManifestObject(localRevision: 1, state: state).serializeBody()
        #expect(throws: VaultError.boundsViolation(.manifest, field: "tombstone_order")) {
            _ = try ManifestObject.parseBody(body)
        }
    }

    @Test func unsortedTrustDevicesRejected() throws {
        let a = try DeviceIdentity.generate()
        let b = try DeviceIdentity.generate()
        let devices = [a, b].map {
            TrustedDevice(
                publicKey: $0.publicKey, role: .member,
                addedAtUnixMS: 1, name: "d")
        }
        let sorted = devices.sorted {
            $0.publicKey.bytes.lexicographicallyPrecedes($1.publicKey.bytes)
        }
        // Hand-craft the payload in DESCENDING order with a valid
        // signature over those bytes — parser must reject on order.
        let reversed = Array(sorted.reversed())
        let payload = SignedTrustList.payloadBytes(
            listVersion: 1, devices: reversed, signer: a.publicKey)
        let signature = a.sign(
            FormatV1.signingBytes(
                domain: FormatV1.trustListSigDomain, galleryID: galleryID, payload: payload))
        var w = WireWriter()
        w.raw(payload)
        w.raw(signature)
        var r = WireReader(w.bytes, object: .manifest)
        #expect(throws: VaultError.boundsViolation(.manifest, field: "trust_device_order")) {
            _ = try SignedTrustList.parse(&r)
        }
    }

    @Test func hostileBoundsRejectedBeforeAllocation() throws {
        let identity = try DeviceIdentity.generate()
        var body = ManifestObject(localRevision: 1, state: makeState(identity)).serializeBody()
        // trust_device_count sits after local_revision(8) + list_version(8).
        body[16] = 0xFF
        body[17] = 0xFF
        body[18] = 0xFF
        body[19] = 0xFF
        #expect(throws: VaultError.boundsViolation(.manifest, field: "trust_device_count")) {
            _ = try ManifestObject.parseBody(body)
        }
    }

    @Test func invalidRoleAndFlagEncodingsRejected() throws {
        let identity = try DeviceIdentity.generate()
        // Tombstone digest flag must be 0 or 1.
        let t = SignedTombstone.minted(
            targetFileID: FileID(), targetDigest: nil, author: identity, galleryID: galleryID)
        var bytes = t.storedBytes
        bytes[16] = 2  // has_target_digest flag
        var r = WireReader(bytes, object: .manifest)
        #expect(throws: VaultError.boundsViolation(.manifest, field: "tombstone_digest_flag")) {
            _ = try SignedTombstone.parse(&r)
        }
    }

    // MARK: - Signature probes (review A3: separate, typed, distinguishable)

    @Test func wrongGalleryFailsAtSignatureLayer() throws {
        let identity = try DeviceIdentity.generate()
        let entry = makeEntry(identity)
        try entry.verify(galleryID: galleryID)
        #expect(throws: VaultError.signatureInvalid(.addEntry)) {
            try entry.verify(galleryID: otherGalleryID)
        }
    }

    @Test func wrongDomainFailsAtSignatureLayer() throws {
        // A signature minted under the TOMBSTONE domain presented as a
        // trust-list signature (same signer, same gallery) must fail:
        // the domain separator binds object kind.
        let identity = try DeviceIdentity.generate()
        let devices = [
            TrustedDevice(
                publicKey: identity.publicKey, role: .owner,
                addedAtUnixMS: 1, name: "d")
        ]
        let payload = SignedTrustList.payloadBytes(
            listVersion: 1, devices: devices, signer: identity.publicKey)
        let wrongDomainSig = identity.sign(
            FormatV1.signingBytes(
                domain: FormatV1.tombstoneSigDomain, galleryID: galleryID, payload: payload))
        let list = SignedTrustList(
            listVersion: 1, devices: devices,
            signerPublicKey: identity.publicKey, signature: wrongDomainSig)
        #expect(throws: VaultError.signatureInvalid(.trustList)) {
            try list.verify(galleryID: galleryID)
        }
    }

    @Test func wrongFormatVersionFailsAtSignatureLayer() throws {
        // A signature over a preamble carrying a different sig version
        // must not verify against the v1 preamble.
        let identity = try DeviceIdentity.generate()
        let entry = makeEntry(identity)
        var forgedPreamble = FormatV1.addEntrySigDomain
        var w = WireWriter()
        w.u16(2)  // future version
        forgedPreamble += w.bytes + galleryID.wireBytes + entry.payloadBytes
        let forged = SignedAddEntry(
            entry: entry.entry, authorPublicKey: entry.authorPublicKey,
            migratedFromV0: entry.migratedFromV0,
            signature: identity.sign(forgedPreamble))
        #expect(throws: VaultError.signatureInvalid(.addEntry)) {
            try forged.verify(galleryID: galleryID)
        }
    }

    @Test func eachTamperedFieldFailsAtSignatureLayer() throws {
        let identity = try DeviceIdentity.generate()
        let base = makeEntry(identity)
        try base.verify(galleryID: galleryID)

        var e = base.entry
        // Tamper each semantic field in turn; the (unchanged, valid
        // Ed25519) signature must stop covering the object.
        let mutations: [(String, () -> InventoryEntry)] = [
            ("file_id", { InventoryEntry(
                fileID: FileID(), aadFileID: e.aadFileID, epoch: e.epoch,
                chunkSize: e.chunkSize, unpaddedLength: e.unpaddedLength,
                dedupHash: e.dedupHash, chunkAddresses: e.chunkAddresses,
                metadata: e.metadata) }),
            ("epoch", { InventoryEntry(
                fileID: e.fileID, aadFileID: e.aadFileID, epoch: e.epoch + 1,
                chunkSize: e.chunkSize, unpaddedLength: e.unpaddedLength,
                dedupHash: e.dedupHash, chunkAddresses: e.chunkAddresses,
                metadata: e.metadata) }),
            ("metadata", { InventoryEntry(
                fileID: e.fileID, aadFileID: e.aadFileID, epoch: e.epoch,
                chunkSize: e.chunkSize, unpaddedLength: e.unpaddedLength,
                dedupHash: e.dedupHash, chunkAddresses: e.chunkAddresses,
                metadata: Array("evil".utf8)) }),
        ]
        for (field, mutate) in mutations {
            let tampered = SignedAddEntry(
                entry: mutate(), authorPublicKey: base.authorPublicKey,
                migratedFromV0: base.migratedFromV0, signature: base.signature)
            #expect(
                throws: VaultError.signatureInvalid(.addEntry),
                "tampered \(field) must fail signature verification"
            ) {
                try tampered.verify(galleryID: galleryID)
            }
        }
        // Author substitution: same payload, another author claims it.
        let other = try DeviceIdentity.generate()
        let reauthored = SignedAddEntry(
            entry: base.entry, authorPublicKey: other.publicKey,
            migratedFromV0: base.migratedFromV0, signature: base.signature)
        #expect(throws: VaultError.signatureInvalid(.addEntry)) {
            try reauthored.verify(galleryID: galleryID)
        }
        // Migration-flag flip.
        let flagFlipped = SignedAddEntry(
            entry: base.entry, authorPublicKey: base.authorPublicKey,
            migratedFromV0: !base.migratedFromV0, signature: base.signature)
        #expect(throws: VaultError.signatureInvalid(.addEntry)) {
            try flagFlipped.verify(galleryID: galleryID)
        }
    }

    @Test func signatureFailureIsDistinguishableFromAEADFailure() throws {
        // Outer AEAD tamper → authenticationFailed(.manifest), never a
        // signature error; inner signature tamper behind a VALID AEAD
        // seal → signatureInvalid. The two layers are typed apart.
        let identity = try DeviceIdentity.generate()
        var state = makeState(identity)
        let object = ManifestObject(localRevision: 1, state: state)
        var dekBytes = randomBytes(32, seed: 1234)
        let dek = try SecureBytes(consumingAndZeroing: &dekBytes)

        var sealed = try object.sealObject(dek: dek, galleryID: galleryID, epoch: 0)
        sealed[sealed.count - 1] ^= 0xFF
        let dekRaw = randomBytes(32, seed: 1234)
        try dekRaw.withUnsafeBufferPointer { raw in
            #expect(throws: VaultError.authenticationFailed(.manifest)) {
                _ = try ManifestObject.openObject(
                    stored: sealed, rawDEK: UnsafeRawBufferPointer(raw),
                    galleryID: galleryID, epoch: 0)
            }
        }

        // Now a STRUCTURALLY valid object whose entry signature is
        // garbage, sealed correctly: AEAD passes, parse passes,
        // signature verification fails typed.
        let badSig = SignedAddEntry(
            entry: state.entries[0].entry,
            authorPublicKey: state.entries[0].authorPublicKey,
            migratedFromV0: false,
            signature: randomBytes(64, seed: 5))
        state.entries = [badSig]
        var dekBytes2 = randomBytes(32, seed: 1234)
        let dek2 = try SecureBytes(consumingAndZeroing: &dekBytes2)
        let sealed2 = try ManifestObject(localRevision: 1, state: state)
            .sealObject(dek: dek2, galleryID: galleryID, epoch: 0)
        try dekRaw.withUnsafeBufferPointer { raw in
            let opened = try ManifestObject.openObject(
                stored: sealed2, rawDEK: UnsafeRawBufferPointer(raw),
                galleryID: galleryID, epoch: 0)
            #expect(throws: VaultError.signatureInvalid(.addEntry)) {
                try opened.state.verifySignatures(galleryID: galleryID)
            }
        }
    }

    @Test func splicedHeadDescriptorRejected() throws {
        // A valid sealed descriptor from commit A pasted behind commit
        // B's plaintext address must fail (the descriptor's inner
        // address is signed and cross-checked).
        let identity = try DeviceIdentity.generate()
        var dekBytes = randomBytes(32, seed: 77)
        let dek = try SecureBytes(consumingAndZeroing: &dekBytes)
        let addressA = ChunkAddress(bytes: randomBytes(32, seed: 8))!
        let addressB = ChunkAddress(bytes: randomBytes(32, seed: 9))!
        let descriptor = SignedHeadDescriptor.minted(
            manifestAddress: addressA, counter: 3, author: identity, galleryID: galleryID)
        var head = try HeadV1.serialize(
            descriptor: descriptor, dek: dek, galleryID: galleryID, epoch: 0)
        // Splice: overwrite the plaintext address with B.
        for (i, byte) in addressB.bytes.enumerated() { head[10 + i] = byte }
        let dekRaw = randomBytes(32, seed: 77)
        try dekRaw.withUnsafeBufferPointer { raw in
            // The AAD does not cover the plaintext address; the SIGNED
            // inner address is the binding — AEAD opens, then the
            // cross-check fails at the signature layer.
            #expect(throws: VaultError.signatureInvalid(.head)) {
                _ = try HeadV1.openDescriptor(
                    head, rawDEK: UnsafeRawBufferPointer(raw), galleryID: galleryID, epoch: 0)
            }
        }
    }

    @Test func trustListSignerMustBeListed() throws {
        let listed = try DeviceIdentity.generate()
        let outsider = try DeviceIdentity.generate()
        let devices = [
            TrustedDevice(
                publicKey: listed.publicKey, role: .owner, addedAtUnixMS: 1, name: "listed")
        ]
        let payload = SignedTrustList.payloadBytes(
            listVersion: 1, devices: devices, signer: outsider.publicKey)
        let list = SignedTrustList(
            listVersion: 1, devices: devices,
            signerPublicKey: outsider.publicKey,
            signature: outsider.sign(
                FormatV1.signingBytes(
                    domain: FormatV1.trustListSigDomain, galleryID: galleryID,
                    payload: payload)))
        #expect(throws: VaultError.untrustedSigner(.trustList)) {
            try list.verify(galleryID: galleryID)
        }
    }
}

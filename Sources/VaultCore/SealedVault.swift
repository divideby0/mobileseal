import Foundation

/// The ciphertext plane. Constructible from a gallery directory alone;
/// every operation here works WITHOUT the DEK: chunk enumeration and
/// copy, address audit, structural `gallery.meta` parsing. Sync,
/// backup, and integrity tooling compile against this plane only. The
/// plaintext plane is reachable solely through `unlock(password:)`.
///
/// Single-process assumption (Codex A2 disposition): VaultCore assumes
/// one process owns a vault directory at a time; multi-process
/// semantics are a CLI-leg question.
public struct SealedVault: Sendable {
    public let directory: URL
    public let meta: GalleryMeta
    let layout: VaultLayout
    let clock: VaultClock

    /// Opens an existing gallery directory: runs startup WAL recovery,
    /// then structurally parses `gallery.meta` (bounds-validated —
    /// including KDF cost floors/ceilings — before anything allocates).
    public init(directory: URL) throws {
        try self.init(directory: directory, clock: .system)
    }

    /// Internal seam: the clock feeds the unlock rate limiter, so it
    /// is deliberately NOT public — a caller-supplied clock would
    /// neutralize backoff (wave-001 claude-code #7). Tests reach it
    /// via @testable.
    init(directory: URL, clock: VaultClock) throws {
        // Sealed-plane operations hash without ever allocating secure
        // memory, so libsodium must be initialized HERE, not lazily on
        // first SecureBytes (wave-002 claude-code #5).
        try SodiumRuntime.ensure()
        let layout = VaultLayout(root: directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
            isDir.boolValue
        else { throw VaultError.notAVault(path: directory.path) }
        Recovery.recover(layout: layout)
        let metaBytes = try FS.read(layout.metaURL, object: .galleryMeta, maxBytes: 64 * 1024)
        self.meta = try GalleryMeta.parse(metaBytes)
        self.directory = directory
        self.layout = layout
        self.clock = clock
    }

    /// Creates a new gallery in format v1: fresh DEK wrapped under the
    /// password at epoch 0, `gallery.meta` written, genesis trust list
    /// signed by the creating device (GOAL WS A.2), and an empty
    /// signed manifest + signed HEAD committed through the normal WAL
    /// protocol so a new vault is indistinguishable from a mutated one.
    public static func create(
        at directory: URL,
        password: borrowing SecureBytes,
        kdfParams: KDFParams = .default,
        identity: DeviceIdentity,
        deviceName: String
    ) throws -> SealedVault {
        try create(
            at: directory, password: password, kdfParams: kdfParams,
            identity: identity, deviceName: deviceName, clock: .system)
    }

    /// Internal seam (see `init(directory:clock:)`).
    static func create(
        at directory: URL,
        password: borrowing SecureBytes,
        kdfParams: KDFParams,
        identity: DeviceIdentity,
        deviceName: String,
        clock: VaultClock
    ) throws -> SealedVault {
        try createShell(at: directory, password: password, kdfParams: kdfParams) {
            layout, galleryID, dek in
            // Genesis: trust list v1 containing exactly the creating
            // device (owner role recorded), signed by it. Attestation
            // beyond this self-signature is a sharing-leg concern
            // (documented; review Q1).
            let genesis = SignedTrustList.minted(
                listVersion: 1,
                devices: [
                    TrustedDevice(
                        publicKey: identity.publicKey, role: .owner,
                        addedAtUnixMS: UInt64(Date().timeIntervalSince1970 * 1000),
                        name: deviceName)
                ],
                signer: identity, galleryID: galleryID)
            let manifest = ManifestObject(
                localRevision: 1,
                state: ManifestState(trustList: genesis, entries: [], tombstones: []))
            let object = try manifest.sealObject(dek: dek, galleryID: galleryID, epoch: 0)
            let tx = try CommitTx(layout: layout)
            _ = try tx.commit(manifestObject: object) { address in
                let descriptor = SignedHeadDescriptor.minted(
                    manifestAddress: address, counter: 1, author: identity, galleryID: galleryID)
                return try HeadV1.serialize(
                    descriptor: descriptor, dek: dek, galleryID: galleryID, epoch: 0)
            }
        }
        return try SealedVault(directory: directory, clock: clock)
    }

    /// Creates a FORMAT v0 gallery (local inventory, plain HEAD).
    /// Internal: exists so migration tests and the v0 KAT fixture
    /// generator can produce pre-migration vaults; production creation
    /// is v1-only.
    static func createV0(
        at directory: URL,
        password: borrowing SecureBytes,
        kdfParams: KDFParams,
        clock: VaultClock = .system
    ) throws -> SealedVault {
        try createShell(at: directory, password: password, kdfParams: kdfParams) {
            layout, galleryID, dek in
            let inventory = Inventory(generation: 1, entries: [])
            let object = try inventory.sealObject(dek: dek, galleryID: galleryID, epoch: 0)
            let tx = try CommitTx(layout: layout)
            _ = try tx.commit(inventoryObject: object)
        }
        return try SealedVault(directory: directory, clock: clock)
    }

    /// Shared creation prologue: directories, DEK, `gallery.meta`,
    /// then the caller's initial commit against the fresh DEK (which
    /// is zeroed on return).
    private static func createShell(
        at directory: URL, password: borrowing SecureBytes, kdfParams: KDFParams,
        initialCommit: (VaultLayout, UUID, borrowing SecureBytes) throws -> Void
    ) throws {
        try SodiumRuntime.ensure()
        try kdfParams.validate()
        let fm = FileManager.default
        let layout = VaultLayout(root: directory)
        guard !fm.fileExists(atPath: layout.metaURL.path) else {
            throw VaultError.ioFailure(operation: "create", path: layout.metaURL.path)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.chunksDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.manifestDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.walDir, withIntermediateDirectories: true)

        let galleryID = UUID()
        let salt = try CryptoCore.randomBytes(CryptoCore.saltBytes)
        var dekBytes = try CryptoCore.randomBytes(CryptoCore.keyBytes)
        let dek = try SecureBytes(consumingAndZeroing: &dekBytes)

        let entry = try GalleryMeta.wrapDEK(
            dek: dek, password: password, galleryID: galleryID,
            salt: salt, kdfParams: kdfParams, epoch: 0)
        let metaBytes = GalleryMeta.serialize(
            galleryID: galleryID, kdfParams: kdfParams, salt: salt, keyring: [entry])
        try FS.write(metaBytes, to: layout.metaURL, fsync: true)
        try FS.fsyncDir(layout.root)
        do {
            try initialCommit(layout, galleryID, dek)
        } catch {
            dek.zeroAndFree()
            throw error
        }
        dek.zeroAndFree()
    }

    // MARK: - Sealed-plane operations (no DEK)

    /// Addresses of every well-named chunk object in the CAS.
    public func chunkAddresses() throws -> [ChunkAddress] {
        try listCAS(layout.chunksDir).addresses
    }

    /// Copies one chunk object out (for sync/backup), verifying the
    /// bytes hash to the requested address first.
    public func copyChunk(_ address: ChunkAddress, to destination: URL) throws {
        let bytes = try FS.read(
            layout.chunkURL(address), object: .chunk, maxBytes: Self.maxStoredChunkBytes)
        let actual = ChunkAddress.compute(over: bytes)
        guard actual == address else {
            throw VaultError.addressMismatch(expected: address, actual: actual)
        }
        try FS.write(bytes, to: destination, fsync: false)
    }

    /// Sealed-plane audit: verifies every CAS object hashes to its
    /// filename and reports HEAD state. Address integrity ONLY — see
    /// `AddressAuditReport` for the tier boundary.
    public func auditAddresses() throws -> AddressAuditReport {
        var mismatched: [String] = []
        var foreign: [String] = []
        var verifiedChunks = 0
        var verifiedInventories = 0

        for (dir, isChunks) in [(layout.chunksDir, true), (layout.manifestDir, false)] {
            let listing = try listCAS(dir)
            foreign.append(contentsOf: listing.foreign)
            for address in listing.addresses {
                let url = dir.appendingPathComponent(address.hex)
                let bytes = try FS.read(
                    url, object: isChunks ? .chunk : .inventory,
                    maxBytes: isChunks ? Self.maxStoredChunkBytes : FormatV0.maxInventoryObjectBytes)
                if ChunkAddress.compute(over: bytes) == address {
                    if isChunks { verifiedChunks += 1 } else { verifiedInventories += 1 }
                } else {
                    mismatched.append(address.hex)
                }
            }
        }

        return AddressAuditReport(
            verifiedChunkObjects: verifiedChunks,
            verifiedInventoryObjects: verifiedInventories,
            mismatchedObjects: mismatched.sorted(),
            foreignFiles: foreign.sorted(),
            headState: headState())
    }

    /// Structural HEAD state (no DEK; AEAD validity of the target is a
    /// session-plane question). Accepts both HEAD formats: v0 (plain
    /// pointer) and v1 (pointer + sealed signed descriptor).
    public func headState() -> AddressAuditReport.HeadState {
        Self.headStateFor(layout: layout)
    }

    // MARK: - Unlock (the only door to the plaintext plane)

    /// Unlocks the gallery (format v1). The password arrives as
    /// NFC-normalized UTF-8 in secure memory and is only borrowed —
    /// never retained. Repeated failures back off locally
    /// (`VaultError.rateLimited`) before the KDF runs.
    ///
    /// `identity` is this device's signing identity (from the
    /// embedder's `DeviceKeyStore`); `deviceName` labels its trust-list
    /// registration. A v0 vault migrates to the signed manifest inside
    /// this call (idempotent state machine, GOAL WS B.6). The rollback
    /// detector (GOAL WS B.7) throws `.manifestRolledBack` when a
    /// KNOWN signer presents an older-than-observed HEAD counter;
    /// re-unlocking with `acceptRollback: true` is the user-visible
    /// "restored from an older backup?" acceptance — it re-baselines
    /// and RECORDS the acceptance in `rollbackStore`.
    public func unlock(
        password: borrowing SecureBytes,
        identity: DeviceIdentity,
        deviceName: String,
        rollbackStore: any RollbackStateStore,
        acceptRollback: Bool = false
    ) throws -> UnlockSession {
        try unlockInternal(
            password: password, identity: identity, deviceName: deviceName,
            rollbackStore: rollbackStore, acceptRollback: acceptRollback)
    }

    /// Internal seam: migration/commit failpoints for crash-injection
    /// tests (green gate 1).
    func unlockInternal(
        password: borrowing SecureBytes,
        identity: DeviceIdentity,
        deviceName: String,
        rollbackStore: any RollbackStateStore,
        acceptRollback: Bool = false,
        migrationFailpoint: MigrationFailpoint = .none,
        commitFailpoint: CommitFailpoint = .none
    ) throws -> UnlockSession {
        // The whole check→KDF→record sequence runs under a per-vault
        // mutex: concurrent guesses must not all observe the same
        // pre-failure limiter state (wave-003 codex #4).
        let gate = VaultProcessRegistry.shared.unlockLock(
            path: VaultProcessRegistry.canonicalPath(layout.root))
        gate.lock()
        defer { gate.unlock() }

        let limiter = UnlockRateLimiter(url: layout.throttleURL, clock: clock)
        try limiter.checkAllowed()

        let epoch = meta.currentEpoch
        let dek: SecureBytes
        do {
            dek = try meta.unwrapDEK(password: password, epoch: epoch)
        } catch let error as VaultError {
            if case .dekUnwrapFailed = error { limiter.recordFailure() }
            throw error
        }
        limiter.recordSuccess()

        let custodian = try KeyCustodian(consuming: dek)
        let loaded = try Self.loadCurrentManifest(
            layout: layout, meta: meta, custodian: custodian, epoch: epoch,
            identity: identity, deviceName: deviceName,
            rollbackStore: rollbackStore, acceptRollback: acceptRollback,
            migrationFailpoint: migrationFailpoint, commitFailpoint: commitFailpoint)
        return UnlockSession(
            vault: self, custodian: custodian, manifest: loaded.manifest, epoch: epoch,
            identity: identity, deviceName: deviceName,
            rollbackStore: rollbackStore, ownCounterBase: loaded.ownCounterBase)
    }

    struct LoadedManifest {
        var manifest: ManifestObject
        /// The base for this device's next HEAD counter: its recorded
        /// high-water mark, or the current HEAD's counter when this
        /// device signed it — whichever is larger.
        var ownCounterBase: UInt64
    }

    /// Loads the manifest HEAD points at, migrating v0 vaults and
    /// recovering damaged HEADs. Recovery rules (docs/formats.md):
    ///   - v1 HEAD → present object: open, verify signatures, verify
    ///     the sealed HEAD descriptor, run the rollback detector.
    ///   - v0 HEAD → present object: load the v0 inventory and run the
    ///     idempotent migration state machine (WS B.6).
    ///   - corrupt/missing HEAD, or HEAD → absent object: fall back to
    ///     the highest-valid-local-generation object across BOTH
    ///     formats (v1 local revision / v0 generation, migration sets
    ///     revision = generation + 1 so the axis is shared; ties
    ///     prefer v1, then the larger address). Repair HEAD.
    ///   - HEAD → present object that fails AEAD: surface the typed
    ///     integrity error — tampering is NOT silently rolled back.
    ///   - nothing valid reachable: `.noValidInventory`.
    static func loadCurrentManifest(
        layout: VaultLayout, meta: GalleryMeta, custodian: KeyCustodian, epoch: UInt32,
        identity: DeviceIdentity, deviceName: String,
        rollbackStore: any RollbackStateStore, acceptRollback: Bool,
        migrationFailpoint: MigrationFailpoint = .none,
        commitFailpoint: CommitFailpoint = .none
    ) throws -> LoadedManifest {
        let galleryID = meta.galleryID

        func openV1(_ address: ChunkAddress) throws -> ManifestObject {
            let stored = try FS.read(
                layout.inventoryURL(address), object: .manifest,
                maxBytes: FormatV1.maxManifestObjectBytes)
            let manifest = try custodian.withKey { raw in
                try ManifestObject.openObject(
                    stored: stored, rawDEK: raw, galleryID: galleryID, epoch: epoch)
            }
            try manifest.state.verifySignatures(galleryID: galleryID)
            return manifest
        }

        func openV0(_ address: ChunkAddress) throws -> Inventory {
            let stored = try FS.read(
                layout.inventoryURL(address), object: .inventory,
                maxBytes: FormatV0.maxInventoryObjectBytes)
            return try custodian.withKey { raw in
                try Inventory.openObject(
                    stored: stored, rawDEK: raw, galleryID: galleryID, epoch: epoch)
            }
        }

        func migrate(from inventory: Inventory) throws -> LoadedManifest {
            try Self.migrateV0(
                inventory: inventory, layout: layout, meta: meta, custodian: custodian,
                epoch: epoch, identity: identity, deviceName: deviceName,
                rollbackStore: rollbackStore,
                migrationFailpoint: migrationFailpoint, commitFailpoint: commitFailpoint)
        }

        let headBytes = FileManager.default.contents(atPath: layout.headURL.path)
            .map { [UInt8]($0) }
        let parsedHead = headBytes.flatMap { try? HeadFile.parse($0) }

        if let parsedHead,
            FileManager.default.fileExists(
                atPath: layout.inventoryURL(parsedHead.address).path)
        {
            switch parsedHead {
            case .v1(let address):
                let manifest = try openV1(address)
                let descriptor = try custodian.withKey { raw in
                    try HeadV1.openDescriptor(
                        headBytes!, rawDEK: raw, galleryID: galleryID, epoch: epoch)
                }
                // The HEAD signer must be a device the manifest's own
                // trust list names (a registration commit always
                // includes its author).
                guard manifest.state.trustList.contains(descriptor.devicePublicKey) else {
                    throw VaultError.untrustedSigner(.head)
                }
                // Rollback detector (WS B.7): fires only on a KNOWN
                // signer presenting an older-than-observed counter.
                if let highWater = try rollbackStore.highWaterMark(
                    galleryID: galleryID, signer: descriptor.devicePublicKey),
                    descriptor.counter < highWater
                {
                    if acceptRollback {
                        try rollbackStore.recordRollbackAcceptance(
                            galleryID: galleryID, signer: descriptor.devicePublicKey,
                            presentedCounter: descriptor.counter,
                            previousHighWaterMark: highWater)
                    } else {
                        throw VaultError.manifestRolledBack(
                            presentedCounter: descriptor.counter, highWaterMark: highWater)
                    }
                }
                try rollbackStore.recordObservation(
                    galleryID: galleryID, signer: descriptor.devicePublicKey,
                    counter: descriptor.counter)
                var ownBase =
                    try rollbackStore.highWaterMark(
                        galleryID: galleryID, signer: identity.publicKey) ?? 0
                if descriptor.devicePublicKey == identity.publicKey {
                    ownBase = max(ownBase, descriptor.counter)
                }
                return LoadedManifest(manifest: manifest, ownCounterBase: ownBase)
            case .v0(let address):
                return try migrate(from: openV0(address))
            }
        }

        // Recovery scan across both formats on the shared
        // local-generation axis.
        var bestV1: (ManifestObject, ChunkAddress)?
        var bestV0: (Inventory, ChunkAddress)?
        let listing = try? listCASDir(layout.manifestDir)
        for address in listing?.addresses ?? [] {
            guard
                let stored = try? FS.read(
                    layout.inventoryURL(address), object: .manifest,
                    maxBytes: FormatV1.maxManifestObjectBytes)
            else { continue }
            if stored.starts(with: FormatV1.manifestMagic) {
                guard let m = try? openV1(address) else { continue }
                if bestV1 == nil || (m.localRevision, address.hex) > (bestV1!.0.localRevision, bestV1!.1.hex) {
                    bestV1 = (m, address)
                }
            } else if stored.starts(with: FormatV0.inventoryMagic) {
                guard let inv = try? openV0(address) else { continue }
                if bestV0 == nil || (inv.generation, address.hex) > (bestV0!.0.generation, bestV0!.1.hex) {
                    bestV0 = (inv, address)
                }
            }
        }
        if let (manifest, address) = bestV1,
            bestV0 == nil || bestV0!.0.generation < manifest.localRevision
        {
            // Repair HEAD with a fresh descriptor signed by THIS
            // device — best-effort in FULL (wave-002 coderabbit):
            // recovery already succeeded, so a failed repair write
            // must not abort the unlock.
            let counter =
                (try rollbackStore.highWaterMark(
                    galleryID: galleryID, signer: identity.publicKey) ?? 0) + 1
            let descriptor = SignedHeadDescriptor.minted(
                manifestAddress: address, counter: counter,
                author: identity, galleryID: galleryID)
            let headTmp = layout.root.appendingPathComponent("HEAD.tmp")
            if let newHead = try? custodian.withKey({ raw -> [UInt8] in
                // Transient DEK copy for the borrowing seal API; its
                // deinit zeroes on scope exit.
                let dekCopy = try SecureBytes(zeroed: CryptoCore.keyBytes)
                dekCopy.withUnsafeMutableBytes { dst in
                    dst.baseAddress!.copyMemory(
                        from: raw.baseAddress!, byteCount: CryptoCore.keyBytes)
                }
                return try HeadV1.serialize(
                    descriptor: descriptor, dek: dekCopy, galleryID: galleryID, epoch: epoch)
            }),
                (try? FS.write(newHead, to: headTmp, fsync: true)) != nil
            {
                _ = try? FileManager.default.replaceItemAt(layout.headURL, withItemAt: headTmp)
                try? FS.fsyncDir(layout.root)
                try? rollbackStore.recordObservation(
                    galleryID: galleryID, signer: identity.publicKey, counter: counter)
                return LoadedManifest(manifest: manifest, ownCounterBase: counter)
            }
            let ownBase =
                try rollbackStore.highWaterMark(
                    galleryID: galleryID, signer: identity.publicKey) ?? 0
            return LoadedManifest(manifest: manifest, ownCounterBase: ownBase)
        }
        if let (inventory, _) = bestV0 {
            return try migrate(from: inventory)
        }
        throw VaultError.noValidInventory
    }

    /// The idempotent v0 → v1 migration state machine (GOAL WS B.6).
    /// Order is normative: device key ensured (the caller's key store
    /// already ran, idempotently) → trust-list genesis staged →
    /// manifest staged → single WAL commit (manifest + HEAD) →
    /// high-water mark initialized. Crash at any step leaves either
    /// the v0 world (HEAD v0 — re-running is a no-op prefix) or the
    /// committed v1 world; the v0 object is superseded exactly at the
    /// commit point.
    static func migrateV0(
        inventory: Inventory, layout: VaultLayout, meta: GalleryMeta,
        custodian: KeyCustodian, epoch: UInt32,
        identity: DeviceIdentity, deviceName: String,
        rollbackStore: any RollbackStateStore,
        migrationFailpoint: MigrationFailpoint = .none,
        commitFailpoint: CommitFailpoint = .none
    ) throws -> LoadedManifest {
        let galleryID = meta.galleryID
        try migrationFailpoint.check(.identityEnsured)

        // Genesis trust list: the migrating device, owner role.
        let genesis = SignedTrustList.minted(
            listVersion: 1,
            devices: [
                TrustedDevice(
                    publicKey: identity.publicKey, role: .owner,
                    addedAtUnixMS: UInt64(Date().timeIntervalSince1970 * 1000),
                    name: deviceName)
            ],
            signer: identity, galleryID: galleryID)
        try migrationFailpoint.check(.genesisStaged)

        // Re-sign every v0 entry as this device, flagged migrated —
        // the storage contract fields ride along verbatim (WS B.2).
        let entries = inventory.entries
            .map {
                SignedAddEntry.minted(
                    entry: $0, author: identity, migratedFromV0: true, galleryID: galleryID)
            }
            .sorted { $0.fileID.wireBytes.lexicographicallyPrecedes($1.fileID.wireBytes) }
        let manifest = ManifestObject(
            localRevision: inventory.generation + 1,
            state: ManifestState(trustList: genesis, entries: entries, tombstones: []))
        let lease = try custodian.leaseKey()
        let object = try lease.withKey { dek in
            try manifest.sealObject(dek: dek, galleryID: galleryID, epoch: epoch)
        }
        try migrationFailpoint.check(.manifestStaged)

        let counter =
            (try rollbackStore.highWaterMark(
                galleryID: galleryID, signer: identity.publicKey) ?? 0) + 1
        let tx = try CommitTx(layout: layout)
        _ = try tx.commit(manifestObject: object, failpoint: commitFailpoint) { address in
            let descriptor = SignedHeadDescriptor.minted(
                manifestAddress: address, counter: counter,
                author: identity, galleryID: galleryID)
            return try lease.withKey { dek in
                try HeadV1.serialize(
                    descriptor: descriptor, dek: dek, galleryID: galleryID, epoch: epoch)
            }
        }
        try migrationFailpoint.check(.committed)
        try rollbackStore.recordObservation(
            galleryID: galleryID, signer: identity.publicKey, counter: counter)
        try migrationFailpoint.check(.highWaterInitialized)
        return LoadedManifest(manifest: manifest, ownCounterBase: counter)
    }

    static func headStateFor(layout: VaultLayout) -> AddressAuditReport.HeadState {
        guard let data = FileManager.default.contents(atPath: layout.headURL.path) else {
            return .missing
        }
        guard let parsed = try? HeadFile.parse([UInt8](data)) else { return .corrupt }
        let address = parsed.address
        guard FileManager.default.fileExists(atPath: layout.inventoryURL(address).path) else {
            return .dangling(address)
        }
        return .valid(address)
    }

    // MARK: - helpers

    /// Largest legal stored chunk object (header + max chunk + tag).
    static let maxStoredChunkBytes =
        ChunkObject.headerLength + Int(FormatV0.maxChunkSize) + CryptoCore.aeadTagBytes

    private func listCAS(_ dir: URL) throws -> (addresses: [ChunkAddress], foreign: [String]) {
        try Self.listCASDir(dir)
    }

    static func listCASDir(_ dir: URL) throws -> (addresses: [ChunkAddress], foreign: [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw VaultError.notAVault(path: dir.path)
        }
        var addresses: [ChunkAddress] = []
        var foreign: [String] = []
        for name in names {
            if let a = ChunkAddress(hex: name) {
                addresses.append(a)
            } else if name != ".DS_Store" {
                foreign.append(name)
            }
        }
        return (addresses.sorted { $0.hex < $1.hex }, foreign)
    }
}


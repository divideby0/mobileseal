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

    /// Creates a new gallery: fresh DEK wrapped under the password at
    /// epoch 0, `gallery.meta` written, and an empty inventory
    /// committed through the normal WAL protocol so a new vault is
    /// indistinguishable from a mutated one.
    public static func create(
        at directory: URL,
        password: borrowing SecureBytes,
        kdfParams: KDFParams = .default
    ) throws -> SealedVault {
        try create(at: directory, password: password, kdfParams: kdfParams, clock: .system)
    }

    /// Internal seam (see `init(directory:clock:)`).
    static func create(
        at directory: URL,
        password: borrowing SecureBytes,
        kdfParams: KDFParams,
        clock: VaultClock
    ) throws -> SealedVault {
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

        // Commit the initial empty inventory (generation 1).
        let inventory = Inventory(generation: 1, entries: [])
        let object = try inventory.sealObject(dek: dek, galleryID: galleryID, epoch: 0)
        let tx = try CommitTx(layout: layout)
        _ = try tx.commit(inventoryObject: object)
        dek.zeroAndFree()

        return try SealedVault(directory: directory, clock: clock)
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
    /// session-plane question).
    public func headState() -> AddressAuditReport.HeadState {
        guard let data = FileManager.default.contents(atPath: layout.headURL.path) else {
            return .missing
        }
        guard let address = try? Head.parse([UInt8](data)) else { return .corrupt }
        guard FileManager.default.fileExists(atPath: layout.inventoryURL(address).path) else {
            return .dangling(address)
        }
        return .valid(address)
    }

    // MARK: - Unlock (the only door to the plaintext plane)

    /// Unlocks the gallery. The password arrives as NFC-normalized
    /// UTF-8 in secure memory (see `SecureBytes.init(nfcNormalizedPassword:)`)
    /// and is only borrowed — never retained. Repeated failures back
    /// off locally (`VaultError.rateLimited`) before the KDF runs.
    public func unlock(password: borrowing SecureBytes) throws -> UnlockSession {
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
        let inventory = try Self.loadCurrentInventory(
            layout: layout, meta: meta, custodian: custodian, epoch: epoch)
        return UnlockSession(
            vault: self, custodian: custodian, inventory: inventory, epoch: epoch)
    }

    /// Loads the inventory HEAD points at. Recovery rules
    /// (docs/formats.md §Recovery):
    ///   - corrupt/missing HEAD, or HEAD → absent object: fall back to
    ///     the newest (highest-generation) AEAD-valid inventory object
    ///     reachable in `manifest/`, and repair HEAD to match;
    ///   - HEAD → present object that fails AEAD: surface
    ///     `.authenticationFailed(.inventory)` — deliberate tampering
    ///     is NOT silently rolled back;
    ///   - nothing valid reachable: `.noValidInventory`.
    static func loadCurrentInventory(
        layout: VaultLayout, meta: GalleryMeta, custodian: KeyCustodian, epoch: UInt32
    ) throws -> Inventory {
        func open(_ address: ChunkAddress) throws -> Inventory {
            let stored = try FS.read(
                layout.inventoryURL(address), object: .inventory,
                maxBytes: FormatV0.maxInventoryObjectBytes)
            return try custodian.withKey { raw in
                try Inventory.openObject(
                    stored: stored, rawDEK: raw, galleryID: meta.galleryID, epoch: epoch)
            }
        }

        switch headStateFor(layout: layout) {
        case .valid(let address):
            return try open(address)
        case .dangling, .missing, .corrupt:
            // Fallback scan: newest valid inventory reachable from CAS.
            var best: (Inventory, ChunkAddress)?
            let listing = try? listCASDir(layout.manifestDir)
            for address in listing?.addresses ?? [] {
                guard let inv = try? open(address) else { continue }
                if best == nil || inv.generation > best!.0.generation {
                    best = (inv, address)
                }
            }
            guard let (inventory, address) = best else {
                throw VaultError.noValidInventory
            }
            // Repair HEAD to the recovered inventory — best-effort in
            // FULL (wave-002 coderabbit): recovery already succeeded,
            // so a failed repair write must not abort the unlock.
            let headTmp = layout.root.appendingPathComponent("HEAD.tmp")
            if (try? FS.write(Head.serialize(address), to: headTmp, fsync: true)) != nil {
                _ = try? FileManager.default.replaceItemAt(layout.headURL, withItemAt: headTmp)
                try? FS.fsyncDir(layout.root)
            }
            return inventory
        }
    }

    private static func headStateFor(layout: VaultLayout) -> AddressAuditReport.HeadState {
        guard let data = FileManager.default.contents(atPath: layout.headURL.path) else {
            return .missing
        }
        guard let address = try? Head.parse([UInt8](data)) else { return .corrupt }
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


import Foundation

/// The plaintext plane's root of authority: move-only proof that this
/// code path performed a successful unlock. `lock()` is `consuming` —
/// using the session after locking is a COMPILE error (regression-
/// locked by the compile-fail harness), and the drain-on-lock protocol
/// (Codex B5) guarantees the DEK allocation is zeroed on return.
public struct UnlockSession: ~Copyable {
    public let vault: SealedVault
    let custodian: KeyCustodian
    /// The signed manifest as of unlock (format v1 — a v0 vault was
    /// migrated inside `unlock`).
    let manifest: ManifestObject
    /// The effective (tombstone-applied) entries as of unlock.
    let visibleEntries: [InventoryEntry]
    let epoch: UInt32
    let identity: DeviceIdentity
    let deviceName: String
    let rollbackStore: any RollbackStateStore
    /// Base for this device's next HEAD counter (see `SealedVault`).
    let ownCounterBase: UInt64

    init(
        vault: SealedVault, custodian: KeyCustodian, manifest: ManifestObject, epoch: UInt32,
        identity: DeviceIdentity, deviceName: String,
        rollbackStore: any RollbackStateStore, ownCounterBase: UInt64
    ) {
        self.vault = vault
        self.custodian = custodian
        self.manifest = manifest
        self.visibleEntries =
            manifest.state.effectiveView(galleryID: vault.meta.galleryID).visibleEntries
        self.epoch = epoch
        self.identity = identity
        self.deviceName = deviceName
        self.rollbackStore = rollbackStore
        self.ownCounterBase = ownCounterBase
    }

    /// Locks the vault: refuses new reads immediately, waits up to
    /// `drainDeadline` seconds for in-flight reads, then zeroes the
    /// DEK unconditionally. Readers that lose the drain race fail
    /// closed with `VaultError.vaultLocked`. Blocks the calling thread
    /// for at most the deadline.
    public consuming func lock(drainDeadline: TimeInterval = 0.5) {
        custodian.lockAndDrain(drainDeadline: drainDeadline)
    }

    /// Opens the single-writer mutation plane. The returned actor
    /// SHARES this session's key custody: locking the session revokes
    /// the gallery's (and all readers') access. Exactly ONE `Gallery`
    /// per session — a second call throws `.galleryAlreadyOpen`
    /// (structural, not advisory: two instances would race the
    /// manifest and silently drop a committed import — wave-001
    /// claude-code #2).
    ///
    /// TOFU note (GOAL WS A.2): if this device is not yet in the trust
    /// list, its registration is folded into the gallery's next commit
    /// automatically; call `Gallery.ensureDeviceRegistered()` to
    /// commit it eagerly.
    public func openGallery() throws -> Gallery {
        // The claim is PROCESS-WIDE per vault directory, not
        // per-session: a second unlock() minting a second writer was
        // the wave-003 blocker (silent lost update).
        let path = VaultProcessRegistry.canonicalPath(vault.layout.root)
        guard custodian.claimWriter(vaultPath: path) else {
            throw VaultError.galleryAlreadyOpen
        }
        return Gallery(
            layout: vault.layout, meta: vault.meta, custodian: custodian,
            manifest: manifest, epoch: epoch,
            identity: identity, deviceName: deviceName,
            rollbackStore: rollbackStore, headCounter: ownCounterBase)
    }

    /// A read-only capability over the effective entries as of unlock.
    /// For reads that must observe later commits, use
    /// `Gallery.makeReader()` against a fresh snapshot.
    public func makeReader() -> ChunkReader {
        ChunkReader(
            layout: vault.layout, galleryID: vault.meta.galleryID,
            custodian: custodian, entries: visibleEntries)
    }

    /// Structural snapshot of the manifest as of unlock (Sendable,
    /// carries no decrypted metadata — Codex B6). `generation` is the
    /// LOCAL commit revision (review Q5).
    public func snapshot() -> InventorySnapshot {
        InventorySnapshot(revision: manifest.localRevision, entries: visibleEntries)
    }

    /// Dropping a session without calling `lock()` still revokes: the
    /// api-shape contract says "deinit self-zeroes", and an escaped
    /// reader or gallery must not keep decrypting against a custodian
    /// whose owning session is gone (wave-003 codex #2). Immediate
    /// deadline: nothing legitimate is draining if the owner was
    /// dropped. Idempotent after an explicit `lock()`.
    deinit {
        custodian.lockAndDrain(drainDeadline: 0)
    }
}

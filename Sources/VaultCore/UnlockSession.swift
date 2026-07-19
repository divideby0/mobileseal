import Foundation

/// The plaintext plane's root of authority: move-only proof that this
/// code path performed a successful unlock. `lock()` is `consuming` —
/// using the session after locking is a COMPILE error (regression-
/// locked by the compile-fail harness), and the drain-on-lock protocol
/// (Codex B5) guarantees the DEK allocation is zeroed on return.
public struct UnlockSession: ~Copyable {
    public let vault: SealedVault
    let custodian: KeyCustodian
    let inventory: Inventory
    let epoch: UInt32

    init(vault: SealedVault, custodian: KeyCustodian, inventory: Inventory, epoch: UInt32) {
        self.vault = vault
        self.custodian = custodian
        self.inventory = inventory
        self.epoch = epoch
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
    /// inventory and silently drop a committed import — wave-001
    /// claude-code #2).
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
            inventory: inventory, epoch: epoch)
    }

    /// A read-only capability over the inventory as of unlock. For
    /// reads that must observe later imports, use
    /// `Gallery.makeReader()` against a fresh snapshot.
    public func makeReader() -> ChunkReader {
        ChunkReader(
            layout: vault.layout, galleryID: vault.meta.galleryID,
            custodian: custodian, entries: inventory.entries)
    }

    /// Structural snapshot of the inventory as of unlock (Sendable,
    /// carries no decrypted metadata — Codex B6).
    public func snapshot() -> InventorySnapshot {
        InventorySnapshot(inventory)
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

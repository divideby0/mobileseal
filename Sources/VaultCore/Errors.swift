/// The on-disk object kinds defined by format v0 (`docs/formats.md`).
public enum VaultObjectKind: String, Sendable, Equatable {
    case galleryMeta = "gallery.meta"
    case chunk
    case inventory
    case head = "HEAD"
}

/// Every failure VaultCore can surface, typed so that callers (and the
/// corruption-matrix tests) can distinguish tampering, misuse, and
/// operational faults. No case ever carries plaintext.
public enum VaultError: Error, Equatable, Hashable, Sendable {
    // -- structural parse failures (sealed plane, no DEK needed) --
    /// Magic bytes did not match the documented constant for the object.
    case badMagic(VaultObjectKind)
    /// Format version is newer than this implementation understands.
    case unsupportedFormatVersion(VaultObjectKind, found: UInt16)
    /// Object is shorter than its declared/required length.
    case truncatedObject(VaultObjectKind)
    /// A declared length or count exceeds the documented hard bound.
    case boundsViolation(VaultObjectKind, field: String)

    // -- KDF parameter validation (before any allocation; Codex B13) --
    /// Stored Argon2id parameters fall outside the documented floors or
    /// ceilings. Thrown before any KDF allocation happens.
    case kdfParamsOutOfBounds(field: String)

    // -- unlock --
    /// The keyring entry failed to open. Wrong password and a tampered
    /// keyring entry are cryptographically indistinguishable; this case
    /// deliberately covers both.
    case dekUnwrapFailed
    /// No keyring entry exists for the requested epoch.
    case unknownEpoch(UInt32)
    /// Unlock refused locally because of repeated failures; retry after
    /// the given number of seconds. The KDF is not run in this state.
    case rateLimited(retryAfterSeconds: Double)
    /// `sodium_malloc` failed; unlock aborts (see docs/formats.md
    /// security notes — mlock failure, by contrast, only warns).
    case secureMemoryUnavailable

    // -- authenticated reads --
    /// An AEAD tag failed to verify on the given object kind.
    case authenticationFailed(VaultObjectKind)
    /// Stored bytes do not hash to the address they are filed under.
    case addressMismatch(expected: ChunkAddress, actual: ChunkAddress)
    /// A chunk referenced by the inventory is absent from the CAS.
    case missingChunk(ChunkAddress)
    /// Tail-chunk padding failed validation (non-zero pad bytes, or a
    /// stored length inconsistent with chunk contents).
    case paddingInvalid
    /// Chunk contents are inconsistent with the entry's declared
    /// unpadded length / chunk count.
    case lengthMismatch

    // -- inventory / HEAD --
    /// HEAD is missing or structurally invalid.
    case corruptHead
    /// No valid inventory object is reachable from the CAS (after HEAD
    /// fallback recovery also failed).
    case noValidInventory
    /// The requested file ID is not present in the inventory snapshot.
    case fileNotFound(FileID)
    /// A requested byte range lies outside the file's unpadded length.
    case rangeOutOfBounds

    // -- key custody --
    /// The vault was locked (or is draining); the read failed closed.
    case vaultLocked

    // -- environment --
    /// An underlying filesystem operation failed.
    case ioFailure(operation: String, path: String)
    /// The gallery directory does not exist or lacks required entries.
    case notAVault(path: String)
}

# Blind code review — CED-13 (claude-code)

## Verdict

This is a strong, defensible implementation of the signed-manifest CRDT,
per-device identity, two-tier delete, and v0→v1 migration described in
`GOAL.md`. The canonical signed encoding is disciplined (fixed field
order, strict-ascending canonical ordering with duplicate/out-of-order
rejection on parse, per-kind signing domain separators, gallery-UUID +
format-version binding in the signing preamble), the verification order
(decrypt → parse → verify signatures) is honored, and the HEAD splice
check (inner sealed address must equal the plaintext pointer) closes the
obvious downgrade path. Device-key custody matches the stated honest
scope: a single audited Keychain↔`SecureBytes` transfer point, no secret
accessor on `DeviceIdentity`, and a compile-fail fixture that pins it.
The merge algebra (identity = `file_id`, migration-equivalence collapse
to smallest canonical digest, exact-bytes tombstone union) and the
device-local rollback detector read correctly and are backed by
property/matrix suites. I built the SPM package (clean) and ran the full
`swift test` target: **115 tests across 25 suites pass**, including the
merge-property, tombstone/trust, rollback-detector, signed-format KAT,
migration crash-injection, and compile-fail custody gates. I found no
blocker or major issues. Two low-severity items are below; the review is
otherwise clean.

## Findings

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | minor | `Sources/VaultCore/SealedVault.swift:440-461` (vs. `373-375`) | Recovery HEAD-repair mints a self-signed HEAD whose signer need not be in the recovered manifest's trust list; the normal v1 load path rejects exactly that, risking a lock-out in a future multi-device window. |
| 2 | nit | `App/MobileSeal/Support/RecentlyDeletedStore.swift:69-71` | `hiddenFileIDs` is dead code — no caller anywhere in the tree. |

---

### 1. Recovery HEAD-repair can write a HEAD the normal load path later rejects

**Evidence.** In `loadCurrentManifest`, the v1-HEAD path enforces that
the HEAD descriptor's signer is in the manifest's own trust list
(`SealedVault.swift:373-375`):

```swift
guard manifest.state.trustList.contains(descriptor.devicePublicKey) else {
    throw VaultError.untrustedSigner(.head)
}
```

But the recovery fallback (`SealedVault.swift:440-461`) repairs a
corrupt/dangling HEAD by minting a fresh descriptor signed by **this**
device against the recovered `manifest`, without checking that this
device is in `manifest.state.trustList`:

```swift
let descriptor = SignedHeadDescriptor.minted(
    manifestAddress: address, counter: counter,
    author: identity, galleryID: galleryID)
... // writes HEAD, returns LoadedManifest(manifest: manifest, ...)
```

If the recovered highest-local-revision manifest does **not** already
list `identity`, the repaired HEAD is signed by an untrusted device.
`adoptUnlocked` immediately calls `ensureDeviceRegistered()` to fold this
device in, so the window is narrow — but a crash/lock between the HEAD
repair write and that registration commit leaves a persisted v1 HEAD
that the *next* unlock rejects with `.untrustedSigner(.head)`, which maps
to `.other(...)` (not a recognized `GalleryFailure`) and blocks unlock.

**Why it matters.** It is a self-contradictory on-disk state: the same
module writes a HEAD that its own load path treats as tampering. It is
**not reachable in this leg's supported single-device configuration**
(the sole device is always the genesis owner and thus always in the
trust list, so recovery always repairs with a trusted signer). It
becomes reachable only once sync lands and a device can recover a
manifest authored solely by peers — which is why I've scored it minor
rather than a blocker. Flagging it now so it's captured before the
sharing/sync legs build on this recovery path.

**Suggested fix.** Either (a) guard the repair so a device absent from
the recovered trust list registers itself (or refuses to author HEAD)
before the repair write, mirroring the `373-375` invariant; or (b)
explicitly document that recovery HEAD-repair assumes `identity ∈
manifest.state.trustList` and add a `precondition`/typed error there, so
the contract is stated at the write site rather than discovered at the
next read.

### 2. `hiddenFileIDs` is dead code

**Evidence.** `RecentlyDeletedStore.hiddenFileIDs` (`RecentlyDeletedStore.swift:69`)
returns the union of *all* member IDs across soft-deleted aggregates, but
a repo-wide search finds no caller. The grid-hiding logic in
`VaultCoordinator.ingest` instead uses only the originals
(`hiddenOriginals = Set(softDeleted.compactMap(\.originalFileID))`,
`VaultCoordinator.swift:386`), which is correct because grid items are
top-level originals.

**Why it matters.** Only clarity/maintenance: a plausibly-security-
relevant helper ("IDs hidden from the grid") that is never wired in
invites a future caller to assume it is load-bearing.

**Suggested fix.** Delete `hiddenFileIDs`, or add the doc note that the
grid filters by original ID and this accessor exists for a not-yet-built
consumer.

REVIEW COMPLETE

# Blind code review — CED-14 Multiple Galleries + Switcher (claude-code)

## Verdict

This is a strong, disciplined implementation that matches the goal spec
closely. The central custody claim — one-live-DEK enforced by a
process-wide serialized `GallerySwitchboard`, with the old gallery's
FULL teardown (thumbnail purge + custodian drain + DEK zero) completing
before the target's KDF begins — is implemented structurally (the FIFO
`transactionTail` chain over the reentrancy-prone actor) and backed by
genuinely adversarial tests (rapid A→B→A, backgrounding-mid-KDF,
switch-during-import, escaped-reader-fails-closed, DEBUG custody-event
ordering). Registry identity keys on the authoritative `gallery.meta`
UUID; locked discovery uses the new read-only `SealedVault.readStructuralMeta`
(no WAL recovery, additive to VaultCore); duplicate/corrupt dirs surface
as non-openable error tiles; the single-gallery migration is idempotent
and crash-injection-tested at every step; per-gallery LockPreferences /
calibration / RecentlyDeleted keying and the ONE shared rollback store
are all honored; the device-local label store degrades every failure
(corrupt / swapped-AAD / missing-key) to a typed generic-tile outcome
with a plaintext-never-on-disk canary. The new files are wired into the
`.xcodeproj`, and VaultCore compiles clean. I found no blocker- or
major-severity issues. The notes below are minor precision/robustness
gaps, none of which break a green gate or the custody invariant.

I did not run the full app/UI xcodebuild suites (simulator-bound,
long-running, and outside a lightweight verify); VaultCore was built to
confirm the additive change compiles.

## Findings

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | minor | `VaultStore.swift:443-447` / `234-238` | Shield purge drops decoded cover `UIImage`s but leaves compressed cover plaintext resident in `galleryLabels` |
| 2 | minor | `VaultStore.swift:302-316`, `423-441` | `coverImages` for every gallery is retained for the whole foreground session — never reset on entering a gallery |
| 3 | nit | `GallerySwitchboard.swift:141-143` | `switchTo(_:)` is reachable only from tests; in-app switching goes through `backToList()` + `select()` |
| 4 | nit | `AppContainer.swift:168-171` | Stale doc comment: "The single gallery this leg manages (Multiple Galleries is the next map ticket)" |

---

### 1. Shield purge leaves compressed cover plaintext resident (minor)

**Evidence.** `sceneBecameInactive()` calls `purgeCoverImages()`
(`VaultStore.swift:237`), which clears only the decoded image dict:

```swift
private func purgeCoverImages() {
    #if os(iOS)
        coverImages = [:]
    #endif
}
```

But the compressed cover bytes live in `galleryLabels` — each
`.labeled(GalleryLabel)` outcome carries `coverJPEG: Data?`
(`GalleryLabelStore.swift:10-16`), and `reloadLabels()` populates
`galleryLabels` for *all* records unconditionally, even while shielded
(the `guard !shielded` at `VaultStore.swift:430` gates only the
`coverImages` decode, not `galleryLabels`). `galleryLabels` is never
cleared by the shield — only overwritten on the next `reloadLabels`.

**Why it matters.** The spec states "covers purge with the global
shield … so covers never appear in the app-switcher snapshot" (GOAL WS
B.2 / plan review Q19). The *snapshot* invariant does hold — only
`coverImages` feeds the tiles, and that is purged before the opaque
shield renders — so this is not a snapshot leak. But the *underlying
cover plaintext* (the compressed JPEG derived from a gallery original)
stays in heap for every labeled gallery while the app is
backgrounded/shielded, which is a slightly wider residual than "covers
purge with the shield" reads as. Impact is low: it is device-local,
opt-in, per-gallery cover material, not cross-gallery secret plane data,
and it is not reachable by the OS snapshot.

**Suggested fix.** If the intent is that no cover plaintext survives the
shield, strip `coverJPEG` from the cached `galleryLabels` in
`purgeCoverImages()` (keep the name for the locked-list tile, drop the
bytes), and re-read on `sceneBecameActive`. Alternatively, document
explicitly that the shield purges the *rendered* cover and the
compressed source persists with the other device-local label material.

### 2. `coverImages` retained across the whole unlocked session (minor)

**Evidence.** `coverImages` is populated by `reloadLabels()` and only
cleared by `purgeCoverImages()` (shield) — never on a route change into
a gallery. `routeChanged(.gallery(...))` (`VaultStore.swift:302-316`)
does not touch `coverImages`, and `reloadLabels()` is called
unconditionally at the end of `sceneBecameActive()`
(`VaultStore.swift:260`) regardless of route, re-decoding covers for
every gallery even when the active surface is an unlocked gallery (not
the list, the only place covers render).

**Why it matters.** Decoded/loaded cover material for galleries the user
is *not* viewing sits in memory for the entire foreground unlocked
session in gallery Y — covers are only ever displayed on the list. This
is negligible incremental exposure relative to the unlocked gallery's
own decoded thumbnail grid, so it is a memory-hygiene / tidiness note,
not a leak. It compounds finding #1.

**Suggested fix.** Gate the cover decode in `reloadLabels()` on
`route == .list` (covers are meaningful only there), and/or clear
`coverImages` when `routeChanged` leaves `.list`. `sceneBecameActive`
would then repopulate only when actually on the list.

### 3. `switchTo(_:)` is test-only in production (nit)

**Evidence.** `GallerySwitchboard.switchTo(_:)`
(`GallerySwitchboard.swift:141`) is invoked only by
`GallerySwitchboardTests.swift:162-166`. Every in-app switch path routes
through `backToList()` (GalleryView "Switch Gallery",
`GalleryView.swift:125-127`; UnlockView Back,
`UnlockView.swift:24-28`) followed by `selectGallery` from the list —
`switchTo` is never wired to UI.

**Why it matters.** It reads as a supported transition but ships as dead
production surface; a reader could wrongly assume the "Switch Gallery"
button calls it. No behavioral impact (its body is a strict subset of
the backToList+select flow the app actually uses).

**Suggested fix.** Either drop `switchTo` and fold its double-switch
race test onto the real `select`/`backToList` entry points, or add a
one-line note that it is an alternate transaction kept for the
race-coverage test.

### 4. Stale doc comment on `existingGalleryDirectory()` (nit)

**Evidence.** `AppContainer.swift:168-171` still reads: "The single
gallery this leg manages (Multiple Galleries is the next map ticket).
Discovery = first directory under galleries/ …". This *is* the multiple
galleries leg; the authoritative discovery is now
`galleryDirectories()` + `GalleryRegistry.scan()`, and this method
survives only as a UI-test / legacy-fixture helper
(`UITestSupport.seedV0VaultIfRequested`, and coordinator-level tests).

**Why it matters.** Purely a documentation drift — the comment now
contradicts the shipped architecture and could mislead a future reader
into treating it as the discovery path.

**Suggested fix.** Reword the comment to "first-gallery helper retained
for UI-test seeding / legacy single-gallery fixtures; production
discovery is `galleryDirectories()` + `GalleryRegistry`."

REVIEW COMPLETE

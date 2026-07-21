# Blind code review — CED-15 media export + share-sheet import (claude-code)

## Verdict

This is a strong, carefully-reasoned change that implements both doors
(export via `UIActivityViewController`, import via a non-unlocking share
extension) with genuinely thorough custody discipline. The hard parts —
the export lock/​background teardown race, the atomic manifest-last inbox
commit, the launch sweep that spares committed items, the exactly-once
prompt bound to the live gallery through the CED-14 switch authority,
integrity re-validation before import — are all present and internally
consistent, and the actor-reentrancy windows around `stage`/`lock` are
handled correctly (files-exist recheck, `activeBatch` sweep, claim
release on teardown). The VaultCore `MediaHashing` unit tests pass
(BLAKE2b-256 known vectors verified). I found **no blocker or major
defects**. The findings below are minor robustness/UX gaps and one
cross-process race with benign impact; none should hold the wave.

I could not run the app-target XCTest suites or `xcodebuild` here
(Swift-package `swift test` for VaultCore was the only cheap gate
available and it is green); the app/extension test coverage looks
comprehensive on inspection but was not executed as part of this review.

## Findings

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | minor | `App/ShareInbox/InboxWriter.swift:287` | Live-Photo copies bypass the low-disk guard — `diskCheck` sizes the bundle *directory* node, not its contents |
| 2 | minor | `App/ShareInbox/InboxStore.swift:254` | Cross-process quota expiry can race a main-app claim/import (no inter-process locking) |
| 3 | minor | `App/MobileSeal/VaultStore.swift:290` | Declined inbox items re-prompt after every app relaunch — the "already prompted" set is session-only, not persisted |
| 4 | nit | `App/MobileSeal/Detail/MediaPagerViewController.swift:100` | Pager single-item Share button is not disabled during an active export, unlike the grid's bulk-share button |

---

### 1. Live-Photo copies bypass the low-disk guard (minor)

**Evidence:** `InboxWriter.diskCheck(for:store:)`
(`App/ShareInbox/InboxWriter.swift:287-296`) computes the required free
space from `fileLength(of: source)`, which is
`attributesOfItem(atPath:)[.size]` (`InboxWriter.swift:298-304`). For a
Live Photo the `source` passed to `loadCopy` is the live-photo *bundle*,
which the code itself treats as a **directory** (`stageLivePhotoBundle`
enumerates it with `contentsOfDirectory(at: bundleURL)`,
`InboxWriter.swift:197`, mirroring `PickerMediaProvider.swift:63`). The
`.size` attribute of a directory node is the directory-entry size (tens
to a few thousand bytes), not the recursive size of the still+video it
contains. So the `available < size * lowDiskFactor` refusal
(`InboxWriter.swift:291`) is effectively a no-op for Live Photos, and the
subsequent per-part `diskCheck(for: source.0)` at
`InboxWriter.swift:217` runs *after* the bundle has already been copied
to `tmpDir` and only guards a same-volume `moveItem` (a rename, which
consumes no additional space).

**Why it matters:** GOAL WS B.1 / gate 3 promise "low-disk refuses new
copies typed" (`InboxError.diskFull`). For a large Live Photo on a
nearly-full disk, the guard does not fire; the `copyItem` in `loadCopy`
(`InboxWriter.swift:269`) fails with a raw Cocoa write error that is
caught and reported as the generic `.copyFailed(...)`
(`InboxWriter.swift:274-275`), not the typed `.diskFull`. The user-facing
extension message then degrades from "not enough free space"
(`ShareViewController.swift:126`) to "the item could not be read"
(`ShareViewController.swift:132`), which is misleading.

**Suggested fix:** In `diskCheck`, when `source` is a directory, sum the
sizes of its contents (or use
`URLResourceValues.totalFileAllocatedSize` over an enumerator) instead of
the directory node's own `.size`. Alternatively, run the disk check
against the *already-copied* bundle in `stageLivePhotoBundle` before the
part moves, sizing the whole bundle.

---

### 2. Cross-process quota expiry can race a main-app claim (minor)

**Evidence:** `InboxStore.enforceQuota` (`InboxStore.swift:254-287`)
runs inside the **share-extension process** during staging: it `scan()`s,
picks the oldest committed *unclaimed* item, and `remove(itemID:)`s it to
make room. Meanwhile the **main-app process** writes claim markers
(`claim(itemIDs:galleryID:)`, `InboxStore.swift:213`) and imports. There
is no inter-process file lock around the scan→remove sequence. An item
observed as unclaimed by the extension's `scan()` can be claimed by the
app in the window before the extension's `remove()`, and `remove()`
deletes by UUID prefix (`InboxStore.swift:239`) — including the
just-written `.claim.json`.

**Why it matters:** The claimed item's payloads then vanish mid-import;
`InboxMediaProvider.stageParts` catches this as
`MediaProviderError.integrityMismatch("payload missing")`
(`InboxMediaProvider.swift:46-51`), which `reconcileInboxClaim`
(`VaultStore.swift`) discards. No crash, no partial import, no plaintext
leak — and the item was under quota pressure and slated to be dropped
anyway — so impact is benign. But it is a real TOCTOU in a
security-sensitive path, and worth an explicit note.

**Suggested fix:** None strictly required given the benign failure mode;
if hardening is wanted, coordinate expiry through a single writer (e.g.
have the extension only *refuse* on quota and let the main app own all
expiry/removal), or gate mutations with an app-group file
coordinator/`NSFileCoordinator`. At minimum, document the race and the
benign resolution alongside the existing quota comments.

---

### 3. Declined inbox items re-prompt after every app relaunch (minor)

**Evidence:** `promptedInboxItemIDs`
(`VaultStore.swift:290`, populated in `discoverInbox`,
`VaultStore.swift:307`) is in-memory session state and is never
persisted. Committed items survive process death by design (the launch
sweep spares them — `InboxStore.sweepAtLaunch`,
`InboxStore.swift:184`). On the next launch `discoverInbox` starts with an
empty `promptedInboxItemIDs`, so any previously-**declined** but still
committed item is treated as "unprompted" and re-pops the import prompt
even with no new arrivals.

**Why it matters:** Codex A4 / GOAL WS B.2 specify "exactly-once prompt
per batch" and decline "re-offer only alongside NEW arrivals." Across a
relaunch the guarantee doesn't hold — a user who declined yesterday is
prompted again today with nothing new staged. This is arguably tolerable
(a fresh session resurfacing pending imports), but it is a deviation from
the stated exactly-once contract and could annoy a user who deliberately
parked items for the Settings view.

**Suggested fix:** Persist the prompted-item set (or a per-item
"declined" marker in the manifest sidecar / a small app-group ledger) so
decline survives relaunch, or explicitly document that relaunch re-offers
pending items as intended.

---

### 4. Pager Share button lacks the `exportActive` guard (nit)

**Evidence:** The grid bulk-share button is disabled while a share is
staging: `.disabled(selection.isEmpty || store.exportActive)`
(`GalleryView.swift`). The pager's single-item Share button
(`MediaPagerViewController.swift:97-101`) has no equivalent guard. A
second tap while a share is still staging reaches
`ExportController.stage`, whose `guard stagingTask == nil, activeBatch ==
nil` (`ExportController.swift:81`) throws
`.stagingUnavailable("an export is already in progress")`, surfaced to
the user as the "Share failed / Couldn't prepare the share…" alert
(`VaultStore.beginExport`, `GalleryView.swift`).

**Why it matters:** Cosmetic only — no custody or correctness impact —
but it's an inconsistent affordance and an avoidable error alert on a
fast double-tap.

**Suggested fix:** Disable the pager Share button while
`store.exportActive` (observe the store from the pager, matching the grid
affordance), or debounce the confirm action.

REVIEW COMPLETE

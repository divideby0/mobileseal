# CodeRabbit findings

Connecting to CodeRabbit... 0s elapsed
Preparing review... 3s elapsed
────────────────────────────────────────
CodeRabbit Review

Diff : committed changes only
Compare : CED-11-ios-vault-app-shell → main
Directory : CED-11-ios-vault-app-shell
────────────────────────────────────────

(\(\
(• .•) Now streaming live: defusing your code bombs.

Summarizing changes... 4s elapsed
Writing review comments... 36s elapsed
Writing review comments... 1m 00s elapsed - still working
Writing review comments... 2m 00s elapsed - still working
Writing review comments... 3m 00s elapsed - still working

────────────────────────────────────────────────────────────────────────
major [Functional Correctness]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/Detail/DetailView.swift:73App/MobileSeal/Detail/DetailView.swift:73-86]8;;

markDamaged fires on transient failures (vaultLocked), producing a
false, persistent damage badge.

Line 74 marks the item damaged for any VaultError, but the switch below
treats .vaultLocked (and the generic default/ioFailure) as
non-damage conditions. A vault that merely locked mid-load is not
corrupted — flagging it damaged mislabels intact media (and diverges from
ThumbnailPipeline, which only reports
.missingChunk/.authenticationFailed).

Restrict markDamaged to the genuine integrity failures.

🐛 Proposed fix

           case .failure(let error):

-            store.markDamaged(item.id)
             switch error {
             case .missingChunk:

*                store.markDamaged(item.id)
                 failure =
                     "Part of this photo's encrypted data is missing from the vault. The rest of your library is unaffected."
             case .authenticationFailed:
*                store.markDamaged(item.id)
                 failure =
                     "This photo's encrypted data failed its integrity check — it may have been corrupted or tampered with. The rest of your library is unaffected."
             case .vaultLocked:
                 failure = "The vault locked while loading."
             default:
                 failure = "Reading failed: \(String(describing: error))"
             }

────────────────────────────────────────────────────────────────────────
major [Security & Privacy]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/Grid/ThumbnailPipeline.swift:88App/MobileSeal/Grid/ThumbnailPipeline.swift:88-95]8;;

Post-purge() insert race can leave plaintext in the cache after lock.

image(for:) awaits task.value at Line 89 with the actor suspended. If
the decode Task finishes (returning a non-nil UIImage) and then
purge() runs during that suspension (clearing
cache/inflight/reader), this call resumes and unconditionally
executes insert(image, for: key) at Line 92 — repopulating cache after
lock.

The Task.isCancelled guard at Line 74 only protects the window before
decode returns; it does not cover an already-completed result whose
consumer resumes post-purge. That breaks the documented purge-on-lock
invariant (GOAL WS D.3) that gate 5 asserts.

The same path is reachable through prefetch (Line 101). Consider a
generation token, or gating the insert on the reader still being live.

🔒 Proposed fix: don't repopulate the cache once the reader has been
dropped

           inflight[key] = task
           let image = await task.value
           inflight[key] = nil

-        if let image {

*        // If the vault locked (reader dropped) while this decode was in
*        // flight, do not repopulate the purged cache.
*        if let image, reader != nil {
             insert(image, for: key)
         }
         return image

Writing review comments... 4m 11s elapsed - still working - 2 findings so far

────────────────────────────────────────────────────────────────────────
major [Security & Privacy]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/AppContainer.swift:47App/MobileSeal/AppContainer.swift:47-61]8;;

Silent failure of backup-exclusion contract.

try? on Line 60 swallows any failure to set isExcludedFromBackup on
stagingDir. Per the file's own doc comment, Staging is "the only
plaintext ever written to disk" and must never be backed up — if
setResourceValues fails here, plaintext material would silently become
backup-eligible with no signal to catch it (in tests or in prod). Given
this is a documented custody guarantee, failures should at least be
surfaced (assert in debug / log in release) rather than discarded.

🛡️ Proposed fix

           var staging = stagingDir
           var values = URLResourceValues()
           values.isExcludedFromBackup = true

-        try? staging.setResourceValues(values)

*        do {
*            try staging.setResourceValues(values)
*        } catch {
*            assertionFailure("Failed to exclude Staging from backup: \(error)")
*        }

────────────────────────────────────────────────────────────────────────
major [Stability & Availability]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/AppContainer.swift:98App/MobileSeal/AppContainer.swift:98-109]8;;

wipeStaging silently ignores removal failures.

The doc comment states this is "the crash-path half of the custody claim"
— if removeItem fails (e.g., file locked, permission edge case) the
try? on Line 107 discards the error, leaving stranded plaintext with no
signal, undermining the exact guarantee this function exists to provide.

🛡️ Proposed fix

           for entry in entries {

-            try? fm.removeItem(at: entry)

*            do {
*                try fm.removeItem(at: entry)
*            } catch {
*                assertionFailure("Failed to wipe staged plaintext at \(entry): \(error)")
*            }
         }

────────────────────────────────────────────────────────────────────────
minor [Performance & Scalability]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/Import/Thumbnailer.swift:5App/MobileSeal/Import/Thumbnailer.swift:5-10]8;;

Doc overstates RAW/DNG embedded-preview reuse

The comment says ProRAW/DNG resolves through the embedded preview, but
kCGImageSourceCreateThumbnailFromImageAlways forces a new thumbnail from
the source image instead of reusing an embedded preview. If preview reuse
is intended, switch to ...IfAbsent; otherwise update the doc.

Writing review comments... 5m 24s elapsed - still working - 5 findings so far
Writing review comments... 6m 24s elapsed - still working - 5 findings so far
Writing review comments... 7m 24s elapsed - still working - 5 findings so far
Writing review comments... 8m 24s elapsed - still working - 5 findings so far
Writing review comments... 9m 24s elapsed - still working - 5 findings so far
Writing review comments... 10m 24s elapsed - still working - 5 findings so far

────────────────────────────────────────────────────────────────────────
major [Data Integrity & Integration]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/VaultCoordinator.swift:296App/MobileSeal/VaultCoordinator.swift:296-318]8;;

lock() doesn't wait for the in-flight import task before dropping
gallery/consuming the session.

lock() calls importTask?.cancel() then immediately nils gallery,
purges the index, and consumes+locks the session (Lines 408-425).
Cooperative cancellation only sets a flag — it does not guarantee the
ImportEngine.run(...) loop running inside importTask (and any
in-flight gallery.importBytes call it triggered) has actually stopped
before the session's key material is drained. Unlike the snapshot feed,
which re-checks self.gallery === gallery per iteration in ingest (Line 261) as a safety net, there is no equivalent guard protecting the import
path from writing to a Gallery whose backing session is being torn down
concurrently.

Awaiting the task before proceeding would close this window:

🔒 Suggested fix

           importTask?.cancel()

-        importTask = nil

*        await importTask?.value
*        importTask = nil
         snapshotTask?.cancel()
         snapshotTask = nil
         gallery = nil

Also applies to: 398-430

────────────────────────────────────────────────────────────────────────
minor [Functional Correctness]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/Support/KDFCalibrator.swift:77App/MobileSeal/Support/KDFCalibrator.swift:77-80]8;;

Misleading fallback reason text on thermal-gate failure.

The thermal gate fires before headroom is ever measured, yet the recorded
reason says "— headroom absent", which conflates the thermal gate with a
headroom rationale. Since this string is persisted for RESULT.md's
device-benchmark gate, it will misdirect anyone reading the record about
why MODERATE was chosen.

💡 Suggested fix

-            return fallback("thermal state \(thermalStateName(thermal)) — headroom absent")

*            return fallback("thermal state \(thermalStateName(thermal)) — raise gate not attempted")

────────────────────────────────────────────────────────────────────────
major [Security & Privacy]
→ ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-11-ios-vault-app-shell/App/MobileSeal/VaultStore.swift:103App/MobileSeal/VaultStore.swift:103-118]8;;

Shield is dropped synchronously before the async grace-period lock
completes — brief unshielded gallery flash.

When the app returns from background after exceeding the grace period,
this function calls lock() (which only schedules `Task { await
  lockAndPurge() }` and returns immediately) and then unconditionally sets
shielded = false on the very next line. Since store.phase is still
.unlocked at that point (the coordinator hasn't hopped actors and
published .locking/.locked yet), ContentView will render
GalleryView with no ShieldView overlay for at least one render pass —
defeating the exact guarantee the shield exists for (Codex A2: never show
vault content without the shield unless actually safe to).

🛡️ Suggested fix — keep the shield up until the lock actually lands

       func sceneBecameActive() {
           NSLog("MOBILESEAL-SCENE active")

-        if let away = backgroundedAt,
-            lockPreferences.backgroundPolicy == .grace,
-            Date().timeIntervalSince(away) > LockPreferences.gracePeriod
-        {
-            lock()
-        }
-        backgroundedAt = nil
-        shielded = false
-        noteInteraction()

*        let awayTooLong = backgroundedAt.map {
*            lockPreferences.backgroundPolicy == .grace
*                && Date().timeIntervalSince($0) > LockPreferences.gracePeriod
*        } ?? false
*        backgroundedAt = nil
*        if awayTooLong {
*            lock()  // shielded stays true until phaseChanged(.locked) clears it
*        } else {
*            shielded = false
*        }
*        noteInteraction()
  }

And clear the shield once locking actually completes, e.g. in
phaseChanged:

func phaseChanged(_ phase: VaultPhase) {
self.phase = phase
if case .unlocked = phase { noteInteraction() }
if case .locked = phase { shielded = false }
}

────────────────────────────────────────
Review complete
8 findings ✔

Major 6
Minor 2

165 files reviewed:

- .coderabbit.yaml
- .gitignore
- App/Fixtures/corrupt-zz.jpg
- App/Fixtures/fixture-0000.jpg
- App/Fixtures/fixture-0001.heic
- App/Fixtures/fixture-0002.jpg
- App/Fixtures/fixture-0003.heic
- App/Fixtures/fixture-0004.jpg
- App/Fixtures/fixture-0005.heic
- App/Fixtures/fixture-0006.jpg
  ... and 155 more files
  ────────────────────────────────────────

Print all AI prompts: coderabbit review --show-prompts

REVIEW COMPLETE

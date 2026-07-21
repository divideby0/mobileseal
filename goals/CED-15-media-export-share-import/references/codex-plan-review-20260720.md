# Codex blind plan review — Media Export and Share-Sheet Import

## Blocking concerns

1. `GOAL.md §Workstream A.1` does not define the actual `UIActivityViewController` item contract: file URLs, `UIActivityItemSource`, or deferred `NSItemProvider` representations. “Stream from decrypted memory” is not implementable as written—data representations materialize `Data`, while Files, AirDrop, and video-oriented activities generally need named file representations; the current `ChunkReader.readRange` also allocates the entire requested range.

2. `GOAL.md §Workstream A.1–A.2` assigns no owner that can cancel and await export decrypt/write operations before lock drains the session and removes staging. `VaultCoordinator.swift §Lock` knows only playback and import, while its whole-root `wipeStaging()` can race an open export file, leaving an unlinked-but-open plaintext vnode that the custody canary cannot detect.

3. `GOAL.md §Workstream A.1` proposes sharing the existing staging discipline without addressing concurrency with import. `VaultCoordinator.swift §Import` wipes the entire staging root when any import finishes, so a concurrent import can delete a large export representation before its activity consumes it; export needs an isolated root or ownership-aware cleanup.

4. `GOAL.md §Workstream A.2` contradicts `VaultStore.swift §scenePhase policy` and `ScenePhaseLockTests`: `.background` locks only under the `.immediate` preference, while `.grace` and `.off` deliberately remain unlocked. The plan must either mandate an export-specific immediate-background override or specify how a share remains safely suspended under those policies; it also cannot retract bytes already delivered to a selected activity.

5. `GOAL.md §Workstream A.1` does not define Live Photo semantics. Supplying a still URL and MOV URL creates two share items and does not guarantee that Save to Photos reconstructs one paired Live Photo; the files require compatible asset identifiers, and destination behavior must be specified as either preserved pairing or intentionally separate assets.

6. `GOAL.md §Workstream B.2` says declined inbox entries persist while also placing the inbox in the launch crash sweep. `AppContainer.swift §Staging lifecycle` currently deletes everything on launch, so the plan needs distinct incomplete, committed, claimed, imported, discarded, and stale states rather than applying the existing wipe-all behavior.

7. `GOAL.md §Workstream B.1–B.2` reduces app-group custody to “Data-Protected” without naming or enforcing a protection class, per-file inheritance behavior, or backup exclusion. The current `AppContainer.swift §prepare` explicitly applies `.completeUnlessOpen` and excludes plaintext staging from backup, but neither contract automatically extends to an app-group container outside the application sandbox.

8. `GOAL.md §Workstream B.1` cites the extension memory limit but does not prescribe a large-video-safe provider path. The extension must copy `loadFileRepresentation` output inside the callback, avoid fallback to whole-object data loading, handle cancellation and disk exhaustion, and bound concurrency; otherwise a valid provider offering only data or an oversized representation can jetsam the extension or strand a partial file.

9. `GOAL.md §Workstream B.1` treats a loose manifest sidecar as sufficient integrity and recovery metadata. It lacks an atomic commit protocol, byte length/hash, representation choice, pairing information, schema version, collision-resistant names, and validation before import, so the host can observe a manifest before its media copy is complete or import a truncated/mismatched file.

10. `GOAL.md §Workstream B.1` does not define incoming Live Photo selection. `PickerMediaProvider.swift §stageParts` prefers one live-photo bundle before considering image or movie conformances; an extension that independently enumerates advertised media representations can duplicate the asset or lose its still/video relationship.

11. `GOAL.md §Workstream B.3` and `Executor notes` do not specify the extension target sufficiently for a sideloadable product. The plan needs a unique extension bundle identifier, extension-point plist and activation rule, embedding dependency, app-group entitlements on both targets, and provisioning profiles for both App IDs; the current unsigned generic-device build in `Scripts/run-gates.sh` cannot prove that the personal team can sign or install this capability set.

12. `GOAL.md §References` assumes CED-14 will produce a `GallerySwitchboard/registry` with an interface suitable for “import into this gallery,” but the parent’s promoted `GOAL.md §Workstream A.2` is still only a specification. The child defines no rebase contract for prompt ownership, gallery switching during inbox claim/import, or lock teardown, so a valid parent implementation can invalidate the proposed routing and tests.

13. `GOAL.md §Green gates 2–4` contains observables that the proposed gates cannot establish. Presenting system activity UI does not verify that Photos, Files, or AirDrop actually request and consume the promised representation; fixture-testing a shared inbox writer does not exercise extension activation, app-group entitlements, process termination, or device-enforced Data Protection.

## Advisories

1. `GOAL.md §Workstream B.1` requires “source app” in the manifest without identifying a supported API that reliably exposes the host application’s identity to a share extension. This field should be optional or removed unless the executor can pin a public source and define behavior when it is unavailable.

2. `GOAL.md §Workstream A.1` does not define filename preservation, duplicate-name handling, or UTI-versus-extension disagreements. These affect how Files and AirDrop present exports even when the payload bytes remain exact.

3. `GOAL.md §Workstream B.2` allows decline to retain plaintext indefinitely without quotas, expiration policy, or low-disk behavior. Repeated shares can therefore exhaust the shared container while still satisfying the stated “bounded by user action” claim.

4. `GOAL.md §Workstream B.2` waits for the “next unlock,” but the host may already be unlocked when the extension completes. The plan should define whether discovery occurs on activation, unlock, gallery switch, or all three, with exactly-once prompting.

5. `GOAL.md §Workstream A.1` does not state when custody transfers from MobileSeal to the OS activity. Completion-handler cleanup cannot cover copies or caches already owned by the chosen activity, so the canary claim must stop at the provider handoff boundary.

6. `GOAL.md §Executor notes` names the moving branch `CED-14-multiple-galleries` as the diff base while that branch is still executing. The launched child needs the parent’s locked commit SHA or RESULT snapshot; otherwise review scope changes underneath the stacked goal.

7. `GOAL.md §Problem` calls export/reimport/delete an enabler for manual cross-gallery moves, but no move orchestration belongs to the stated workstreams. Tests or implementation that add automated deletion, destination selection, or cross-gallery transactions would be scope leakage.

## Questions the plan leaves unanswered

1. `GOAL.md §Workstream A.1`: What exact activity item is supplied for a still, ordinary video, and Live Photo? The answer must include filename, UTI, representation API, and whether one Live Photo counts as one selected aggregate or two share items.

2. `GOAL.md §Workstream A.1`: What byte threshold selects memory versus file staging, and what measured memory budget justifies it? How is the large path forced deterministically without committing a huge fixture?

3. `GOAL.md §Workstream A.2`: Does export override `.grace` and `.off` background policies, or may the session remain unlocked while an external activity owns the foreground? At what point is cancellation no longer claimed to recall shared bytes?

4. `GOAL.md §Workstream B.1–B.2`: What protection class, backup policy, retention limit, byte quota, and incomplete-copy recovery rule apply to the app-group inbox? Which of those properties can be simulator-gated and which remain device-only residuals?

5. `GOAL.md §Workstream B.1`: What is the canonical manifest schema and atomic publication order? How are malformed UTIs, false extensions, truncated media, duplicate manifests, paired resources, and concurrent extension invocations handled?

6. `GOAL.md §Workstream B.2`: Which CED-14 authority atomically binds an inbox claim to a gallery, and what happens if the user switches or locks galleries during import? The parent goal currently promises serialization but no child-consumable API.

7. `GOAL.md §Workstream B.3`: Which developer team and provisioning setup is assumed, and is App Groups available to that sideloading account? What signed build or profile inspection replaces the unsigned generic-device build as feasibility evidence?

8. `GOAL.md §Green gates 2–3`: What test seam drives provider consumption, completion, cancellation, extension termination, and relaunch without tapping system UI? Merely asserting that controllers and manifests exist does not exercise the custody lifecycle being claimed.

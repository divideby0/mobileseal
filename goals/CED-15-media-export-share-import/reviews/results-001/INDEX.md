# Review results-001

Blind multi-tool review wave for `CED-15-media-export-share-import` (2026-07-21T05:51:17.423Z).
Each reviewer ran as a labeled tab in the executing session's own herdr
workspace. Model/effort/args columns record per-reviewer provenance;
`(default)` means nothing was passed and the harness kept its own default.

All reviewers completed.


| Tool | Outcome | Findings | Model | Effort | Args | Detail |
|---|---|---|---|---|---|---|
| claude-code | completed | [FINDINGS.md](claude-code/FINDINGS.md) | opus | high |  |  |
| codex | completed | [FINDINGS.md](codex/FINDINGS.md) | (default) | (default) |  |  |
| sonarqube | completed | [FINDINGS.md](sonarqube/FINDINGS.md) | (default) | (default) |  |  |
| coderabbit | completed | [FINDINGS.md](coderabbit/FINDINGS.md) | (default) | (default) |  |  |

## Merged findings

13 findings across the four reviewers (claude-code 4, codex 5,
sonarqube 0 open, coderabbit 4), deduplicated to 12 — claude-code #2
and codex #2 hit the same cross-process quota surface from different
angles (merged as one); claude-code #1 and coderabbit #4 both live in
the live-photo staging path but are different defects (kept separate).
Dispositions by the executing session's judgment; fixes land in the
reconciliation commit, verified by the full unit suite (123 tests) and
a fresh full `run-gates.sh` sweep.

**Fixed — 9:**

1. **codex #1 (major)** — export staging ran in a `Task {}` that
   inherits the ExportController actor executor: the synchronous
   slice loop starved `prepareForLock`/`cancelActiveExport` until the
   whole export finished — unbounded lock latency, uncancellable
   plaintext write; the grace/off background cancel also lacked a
   suspension shield. FIXED: staging is `Task.detached` (per-slice
   `checkCancellation` now observes teardown promptly), and the
   grace/off path wraps the cancel in a `beginBackgroundTask`
   assertion, mirroring the lock path. New DETERMINISTIC test
   (`lockCancelsProvablyInFlightStaging`): a slice-hook gate parks
   staging provably in flight, the lock's cancel is observed via a
   probe, and the very next cancellation check wins — the old
   postcondition-only race test remains alongside.
2. **codex #2 (major, merged with claude-code #2)** — quota eviction
   deleted committed items BEFORE the incoming manifest committed (a
   writer dying mid-item destroyed old items for a share that never
   landed), and the extension's scan→remove could race a main-app
   claim (TOCTOU). FIXED structurally where it matters: quota is now
   plan (before commit, still refusing typed when the item can never
   fit) → commit manifest → execute plan (after), and execution
   re-checks each victim's claim marker, SKIPPING victims claimed
   since planning (new tests for both). Residual, recorded and
   accepted this leg: there is still no interprocess lock, so two
   extension processes racing the same boundary can transiently
   exceed the quota (next writer trims), and a claim landing inside
   the execute window can still lose its payloads — which then fails
   typed (`integrityMismatch`, payload missing) and discards: the
   same terminal state the expiry intended. A real interprocess
   transaction (SQLite/NSFileCoordinator) is deliberately out of
   scope — follow-up candidate, see RESULT.md.
3. **codex #3 (major)** — extension Cancel discarded the provider's
   cancellation handle (`Progress`), the load continuation had no
   cancellation handler, and `cancelRequest` fired without awaiting
   writer cleanup — iOS could kill the process before the typed
   cleanup ran. FIXED: the `InboxAttachment` seam now RETURNS a
   cancel handle, `loadCopy` bridges it via
   `withTaskCancellationHandler` + a single-resume box, and
   `ShareViewController.cancel` disables the UI, cancels, AWAITS the
   writer, and only then ends the request. The fake attachment
   honors the same contract (cancel interrupts its delay), so the
   cancellation test now exercises the real plumbing.
4. **codex #4 (minor)** — batch claim markers were written in a loop
   with no rollback: a failed Nth write left a half-claimed batch
   invisible until relaunch. FIXED: `InboxStore.claim` is
   all-or-nothing — every marker written before a failure is removed
   before the error propagates. (The injected-failure test codex
   suggested is not implemented — the rollback is four lines above
   the throw and the orphan-claim launch sweep already covers the
   crash-mid-rollback case; recorded honestly rather than silently.)
5. **codex #5 (minor)** — one-second ISO-8601 `committedAt` made
   "oldest committed first" arbitrary within a normal batch. FIXED:
   all inbox sidecars now encode fractional-second dates (decoding
   accepts both forms), and both scan sorts tie-break on `itemID`
   for a total order.
6. **claude-code #1 (minor)** — the live-photo disk-full guard sized
   the bundle DIRECTORY node (tens of bytes), not its contents, so
   the typed `.diskFull` refusal never fired for the largest intake
   path. FIXED: `representationSize(of:)` sums a directory's regular
   files recursively; new test proves the typed refusal fires with
   no stranded partials.
7. **claude-code #3 (minor)** — the prompted-batch ledger was
   session-only, so a DECLINED batch re-prompted after every
   relaunch, breaking the exactly-once contract (Codex A4). FIXED:
   prompted IDs persist in `prompted.json` beside the items (pruned
   to live items on write); new test drives a second store stack
   over the same inbox — no re-prompt until a NEW arrival joins.
8. **claude-code #4 (nit)** — the pager Share button lacked the
   grid's `exportActive` guard; a fast double-tap surfaced the
   "already in progress" error alert. FIXED: the pager's confirm
   action guards on `store.exportActive`.
9. **coderabbit #2 (minor)** — the streamed-vs-in-memory hash test's
   "cross the 1 MiB buffer" input was 3 << 18 = 768 KiB — under the
   buffer. FIXED: input is now 1 MiB + 4 KiB.

**Fixed (defense in depth) — 2:**

10. **coderabbit #1 (major as filed; judged defense-in-depth)** —
    `InboxMediaProvider` verified the SOURCE payload then copied it,
    so a substitution between check and copy could stage unverified
    bytes. The window requires an attacker who can already write the
    app-group container mid-import, but the fix is cheap and the
    posture is right: the staged COPY is re-verified (length + hash)
    after `copyItem`, before the part is returned. FIXED as proposed.
11. **coderabbit #4 (minor)** — a live-photo staging failure between
    the two payload moves stranded `-0.payload` AND the `try?`
    fallback then masked the real error (e.g. `.diskFull`) as
    `.copyFailed`. FIXED both halves: partial moves roll back on
    error, and the fallback contract is now honest — disk-full and
    cancellation propagate typed; only genuine
    can't-deliver-the-bundle failures fall through to the plain
    image/movie branches.

**Rejected with reason — 1:**

12. **coderabbit #3 (major as filed)** — "stage() can return a batch
    after tearDownExports() swept it; add a generation counter."
    REJECTED AS FILED — the files-exist recheck already caught the
    sweep-wins ordering — but the residual ordering (stage resumes
    first, hands out a batch the pending teardown then kills) was
    real as a UX wart, and the suggested generation counter was the
    right shape: implemented (`teardownGeneration`), so a staging
    task that raced ANY teardown now refuses the handout
    deterministically. Recorded as rejected-then-adopted-in-substance
    rather than "fixed" because the custody claim was never at risk:
    the participant sweep runs regardless of what stage() returns.

Sonarqube: 0 open issues on the ephemeral branch project
(`mobileseal-CED-15-media-export-share-import`, compute task
`2b83a170-e956-4250-891a-56e18089306b`) — nothing to reconcile.

Folder-naming note: the wave writer emitted `reviews/results-001/`
(the same upstream naming deviation CED-13/CED-14 recorded — wave-NNN
is the documented shape); left as generated.

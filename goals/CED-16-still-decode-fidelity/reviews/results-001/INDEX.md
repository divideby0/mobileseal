# Review results-001

Blind multi-tool review wave for `CED-16-still-decode-fidelity` (2026-07-21T06:47:39.645Z).
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

Two findings across four reviewers (codex: none; sonarqube: 0 open on
the ephemeral branch project, compute task `696b2b96…`). No overlap
between reviewers, so 2 merged findings, reconciled as follows.

### 1. Eager full-res decode on preloaded neighbor pages — FIXED

- **Source**: claude-code #1 (minor) —
  `MediaPageViewController.swift:101`.
- **Finding**: the full-res decode ran in `viewDidLoad`, so pager
  neighbor preloading held 2–3 ~44 MiB 4096-px stills at once; the
  CED-11 ceiling comment budgets one on-screen still plus transition
  headroom, and the pre-fix 432-px previews had masked the overshoot.
- **Disposition**: fixed in `fc61f1d` — the reviewer's first
  suggested remedy. `decodeFullStill` is now gated on `didLand()`
  (all three landing paths route through `landed(on:)`); neighbors
  keep their 512-px poster, swipe-away cancels the task, re-landing
  retries only when no full decode ever succeeded. Verified by the
  full unit suite (128 tests) and a full post-fix `run-gates.sh`
  sweep (pager prefetch + scroll perf gates included).

### 2. `kCGImageSourcePropertyRawDictionary` is not an ImageIO key — REJECTED (moot in code, spec text left as history)

- **Source**: coderabbit #1 (minor, Functional Correctness) —
  `GOAL.md:41-42`.
- **Finding**: the goal SPEC names `kCGImageSourcePropertyRawDictionary`;
  copying that identifier into `StillDecoder` would not compile.
- **Disposition**: rejected as a code change — the shipped detection
  already uses the real key, `kCGImagePropertyRawDictionary`
  (`StillDecoder.usesEmbeddedPreview`), alongside
  `kCGImagePropertyDNGDictionary` and the `UTType.rawImage`
  conformance check, and it compiles + passes the routing tests. The
  misspelling lives only in GOAL.md's scope prose, which mirrors the
  promoted Linear issue body; rewriting promoted spec text after the
  fact would desync the issue's pinned permalinks for a cosmetic fix.
  Recorded here (and in RESULT.md) instead.

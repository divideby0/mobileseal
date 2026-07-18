# Handoff Output Template

Structure for the handoff file. Follow exactly — the next session relies on
these section names. Adapted from REMvisual/claude-handoff's template; chain
metadata retargeted from "beads/epic" onto evie-agent's goal/loop-folder
slugs (no external ticketing tool assumed).

````markdown
# {One-line summary of current work}

**Date:** {YYYY-MM-DD}
**Status:** {COMPLETED | IN PROGRESS | BLOCKED}
**Goal/Loop folder:** {path, or "none — standalone"}
**Chain:** `{chain_tag}` seq `{N}`
**Parent:** `{parent_filename}` or `none — first in chain`
**Prior chain:** `{file1}` > `{file2}` > ... > this (or "none — first in chain")

{chain_tag examples:

- Goal: `ABC-1-some-goal-slug` (promoted) or
  `20260710-214424-goals-workflow` (still-draft form)
- Loop: `loop-20260710-195700-claude-notification-research`
- No goal: `standalone-a1b2c3d4`}

---

## Stale References

{INCLUDE ONLY if a parent existed and some identifiers from it aren't in the
current codebase. Format:

- `old_identifier` — not found in codebase (was in parent seq N)

Don't guess why; flag only. Next session resolves by reading code.
OMIT entirely if all identifiers check out.}

## Related Handoffs

{INCLUDE ONLY if other handoffs exist on the same goal/loop folder that
AREN'T chain parents (separate work streams within the same goal). Format:

- `handoff-<date>-other-topic.md` — {1-line topic}, separate work stream
  OMIT if none.}

## Since Last Handoff

{INCLUDE ONLY if parent exists (seq > 1). Compare parent's plan vs reality:

- Parent's "Where We're Going" vs what actually happened
- Which open questions got answered
- Which risks materialized
- Trajectory: still on path, or did priorities shift?
  3-8 bullets. Momentum, not snapshot. OMIT entirely if seq 1.}

## Reference Documents

{INCLUDE ONLY if relevant docs exist:

- `goals/.../GOAL.md` — the goal this session works
- `packages/<pkg>/CONTEXT.md` — domain glossary for the touched package
- `docs/adr/NNNN-*.md` — relevant architectural decisions
  OMIT if none.}

## The Goal

{3-5 sentences: overarching objective, why it matters, end state. If this
session works a goal folder, frame this against that GOAL.md rather than
restating it — link, don't duplicate.}

## Where We Are

{15-25 bullets: every file/function changed, test counts, measurements with
real numbers, what works/doesn't. Under 10 = too aggressive.}

## What We Tried (Chronological)

{Every approach: hypothesis -> changes -> result (with numbers) -> why it
worked or didn't. Most expensive section to re-derive if skipped. 5-15
entries. Include prior-session context if a parent exists.}

## Key Decisions

{Every non-obvious decision + why. Include rejected alternatives. 5-10
bullets. Cross-reference any ADR written for a decision instead of restating
its rationale.}

## Evidence & Data

{All raw data from the session:

- Comparison tables (approach A vs B vs C with metrics)
- Iteration histories (v1->v2->v3, what changed, results)
- Status matrices (N/M complete)
- Commit logs (hash + summary table for 5+ commits)
- Benchmark numbers, accuracy %, error rates
- Data file paths for raw results

Never say "improved" — say "improved from X to Y". Use markdown tables.
8-20 items minimum for a Deep pass.}

## Code Analysis

{Function signatures, thresholds, constants, architecture, coupling. Skip if
no deep code reading happened. 5-10 bullets.}

## Files Changed

{Grouped by purpose:

### Source code

- path/to/file.ts — what changed and why

### Tests

- path/to/file.test.ts — what was tested

### Data & results

- path/to/results.json — what it contains

### Config

- path/to/config — what changed}

## User Feedback & Preferences (REQUIRED — never omit)

{Every piece of direction the user gave: direct corrections, preferences,
frustrations, feature requests, process feedback ("stop asking, just do
it"). This is the user's voice — calibrates the next session's approach.
5-15 items for heavy sessions.}

## Where We're Going

{Ordered next steps with phase/step numbers. 3-7 bullets.}

## Risks & Blockers

{Upstream deps, flaky areas, env issues. 2-5 bullets. "None" if clear.}

## Open Questions

{Unknowns needing investigation. 1-5 bullets. "None" if answered.}

## Quick Start for Next Session

```bash
# Restore context
cat {goal-or-loop-folder}/GOAL.md   # or goal.md

# Key files to read first (not exhaustive)
{3-5 most important files}

# Evidence / data files
{paths to test results, measurements}

# Verify current state
{test command or validation step}

# Next action
{THE single most important thing to do next}
```

## Self-Check (REQUIRED — never omit)

{The validation trace — the SINGLE SOURCE for what this section records is
right here; SKILL.md Step 6 and validation.md §6 point at this block rather
than restating it. Fill it in during Step 6, LAST — after the gap pass and
after every validation fix has landed. Record what was actually checked,
not aspirations. This is the audit trail that makes self-validation visible
in the artifact instead of vanishing with the session that ran it:

- **Pass:** {Quick | Deep} — {one line: why this pass fit the session}
- **Line count:** {N} against floor {F} / ceiling {C} — {met on first
  write | expanded from {M} in the gap pass}
- **Gap pass:** {one line per section expanded, naming what was added; or
  "nothing found to expand" — on a long session that claim is suspicious,
  so say why it's credible}
- **Completeness:** {each checklist item that initially failed and how it
  was fixed; or "all checks passed on first read-back"}
- **Not captured:** {anything knowingly omitted — redacted secrets, detail
  already recorded in a GOAL.md/ADR/commit and referenced instead, stale
  threads deliberately dropped — so the next session can tell a deliberate
  omission from a mining gap. "Nothing deliberately omitted" if so — but
  that's rarer than it sounds: the redactions and
  reference-instead-of-restate choices Step 5 requires usually belong
  here.}}
````

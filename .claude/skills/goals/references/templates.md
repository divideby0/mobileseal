# Goal artifact templates

Format specs for the artifacts the lifecycle produces beyond the
frontmatter and `MAP.md` templates already in SKILL.md /
`references/wayfinder.md`. Read the relevant section before writing the
artifact. Each template says whether it is **generated** (code writes
this exact shape — never hand-invent a divergent one) or **convention**
(assembled by the agent; the shape below is what every real goal folder
on main follows).

Contents: [GOAL.md body](#goalmd-body) ·
[results/RESULT.md](#resultsresultmd) ·
[Review wave INDEX.md](#review-wave-indexmd) ·
[Tracker issue body](#tracker-issue-body)

## GOAL.md body

**Convention** (verified against `@evie-agent/goals`' `createDraft`,
which generates only the H1 — everything below it is authored during
drafting/refinement):

```markdown
# {Verb-prefixed Title Case title, 35–50 chars — same rules as the tracker issue title it becomes}

## Problem

{Why this goal exists: the defect, gap, or opportunity, with pointers
to evidence (audit findings, prior goals, code). If this goal
supersedes drafts or references locked goals, say so here.}

## Scope

{What to build/change, concrete enough for a fresh executor session.
Split into `### Workstream X — name` subsections when there are
independent chunks; number the steps inside each.}

## Green gates

{Numbered list — THE definition of "done", authored at drafting time
(lifecycle step 7 gates on these). Each gate must be checkable by the
executing session itself: a measurable state ("body under 500 lines",
"no pass-rate regression"), a passing tool run, or a completed review
wave. The blind multi-tool review wave is the default final gate for
coding goals.}

## References

{Pointers the executor will need: prior goals' artifacts, research
docs, vendored specs. Reusable research belongs in project-level
`research/`, linked from the goal's `references/INDEX.md`.}

## Executor notes (self-sufficiency)

{Everything a fresh session needs that isn't derivable from the repo:
setup steps, credentials location, known gotchas from prior waves,
commit/branch conventions, the completion procedure. GOAL.md must be
self-sufficient — this section is where that promise is kept.

Always include the goal's diff base: "Review-wave diff base: `main`" —
or, for a stacked goal, "Review-wave diff base: `<stacked_on parent>`
(this goal stacks on it; waves diff `<parent>...HEAD`, never the
parent's own changes)". The wave driver derives BASE from the
`stacked_on` frontmatter; this line makes the executor expect it.}
```

## results/RESULT.md

**Convention** (the shape every completed goal's RESULT.md on main
follows):

```markdown
# {ISSUE-KEY} Result: {Goal Title}

## What changed

{Narrative of the work actually done: commits (hash + subject), files,
and the why behind non-obvious choices. Written for the next goal's
executor and the map-level reformulation pass — record friction and
surprises, not just outcomes.}

## What did NOT need changing

{Scope items that turned out already-done or unnecessary, with the
evidence — prevents the next session from re-deriving the same
conclusion. Omit if empty.}

## Gate {N} — {gate name, one section per green gate, in GOAL.md order}

{Evidence the gate passed: real numbers, command output summaries,
links to committed artifacts (benchmarks, review INDEX.md). A gate
that was adjusted or waived is recorded here with the user decision
that authorized it — never silently.}

## Follow-ups

{Anything surfaced but out of scope — candidate new goals, each
referencing this one. Omit if none.}
```

## Review wave INDEX.md

**Generated** — `@evie-agent/goals`' `runReviewWave` writes this
exact shape; the executing
session then EDITS the "Merged findings" section in place:

```markdown
# Review wave-{NNN}

Blind multi-tool review wave for `{goal-folder-name}` ({ISO timestamp}).
Each reviewer ran as a labeled tab in the executing session's own herdr
workspace. Model/effort/args columns record per-reviewer provenance;
`(default)` means nothing was passed and the harness kept its own default.

{verdict line — one of:
"All reviewers completed." |
"All live reviewers completed; skipped (recorded, not silent): {tools}." |
"WAVE FAILED: {tool (status), …} — failures are reported, never
silently absorbed; rerun or reconcile explicitly."}

| Tool | Outcome | Findings | Model | Effort | Args | Detail |
| ---- | ------- | -------- | ----- | ------ | ---- | ------ |

{one row per tool in the wave: outcome status, FINDINGS.md link,
provenance, skip/failure detail — plus one terse row per tool ABSENT
from the wave (`not-configured`, or `not-in-wave` when the driver
didn't pass `definedTools`): no findings link, rendering only, never
part of the wave verdict (EVA-11 enabled-only semantics)}

## Merged findings

{Generated as a "RECONCILIATION REQUIRED" placeholder. The wave is
not a passed gate until the executing session replaces it: read every
reviewer's FINDINGS.md, merge the findings, and record each one's
disposition (fixed / rejected-with-reason / deferred-to-new-goal) by
its own judgment — no mechanical union or vote rule.}
```

## Tracker issue body

**Convention** (assembled by the promotion step's `createIssue`
callback — `promoteGoal` hands it the parsed GOAL.md and a
commit-pinned permalink builder):

- The body **mirrors the GOAL.md body** section-for-section (Problem,
  Scope, Green gates, …) — it is the same spec on a shareable,
  team-visible surface, not a summary of it.
- Every pointer to a repo file becomes a **git permalink with the
  pushed head commit baked in** (the branch is pushed before the issue
  is drafted precisely so these resolve), rendered as inline Markdown
  links; external URLs stay plain links.
- The issue title is the GOAL.md H1 (verb-prefix, Title Case, 35–50
  chars — plus any issue-title conventions the project's team keeps);
  the issue lands where the layered `.evie-agent` settings'
  `tools.tracker.*` block points (EVA-26): the Linear team/project of
  `tools.tracker.linear`, or the GitHub repo of `tools.tracker.github`
  — never a destination hardcoded in skill text. A team may keep a
  separate sandbox project for throwaway dogfood goals.
- After promotion the issue is the primary review surface (lifecycle
  step 4); GOAL.md remains the executable source of truth.

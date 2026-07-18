# Attribution

This skill has two sources, merged into one:

## 1. The core lifecycle (draft → promote → execute → review → lock)

Original design — not adapted from an external skill. Worked out in a
design conversation on Discord (#evie-agent and #vermeulens-infra,
2026-07-10), refined through a `grill-me` interview across ten questions
(2026-07-10/11), and originally written up as its own goal at
`goals/drafts/20260710-214424-goals-workflow/GOAL.md`. Full transcript of
the refining interview: that goal's `grilling/session-001-20260710-221700.md`.

## 2. Wayfinder mode (oversized-idea planning)

Adapted from [mattpocock/skills](https://github.com/mattpocock/skills)
`skills/engineering/wayfinder`, retargeted from a generic issue tracker onto
Linear specifically (the source skill is tracker-agnostic; we picked Linear
since that's this repo's actual tracker).

Originally built and shipped as its own standalone skill
(`.claude/skills/wayfinder/`) before being folded into this one. The merge
decision: under this repo's own methodology, nothing ever gets built except
through a goal, so a wayfinder map that never resolves into one or more
goals is a map that goes nowhere — it's never actually independent of the
goals lifecycle in practice, even though the upstream skill is generically
reusable. Rather than maintain two skill files with a cross-reference
between them, wayfinder became this skill's mode for handling ideas too big
for a single execution session — the same shape of decision that folded
`handoffplan` into `handoff` as a mode rather than a fifth skill (see the
`handoff` skill's own attribution for that precedent).

Nothing else about wayfinder's mechanics changed in the merge — the Map
structure, ticket types, fog-of-war discipline, one-execution-loop-at-a-time
rule, and persistent references store are all preserved verbatim from the
standalone version, just filed under this skill's "Wayfinder mode" section
instead of their own SKILL.md.

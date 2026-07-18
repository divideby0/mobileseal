# Attribution

Primary source: [REMvisual/claude-handoff](https://github.com/REMvisual/claude-handoff)
(`skills/handoff`, `skills/handoffplan`, `hooks/precompact-handoff.sh`) — a
notably more rigorous handoff design than the alternative found in
[mattpocock/skills](https://github.com/mattpocock/skills), which has two
much thinner variants: `skills/productivity/handoff` (writes a file to the OS
temp dir, no chain tracking) and `skills/in-progress/claude-handoff` (spawns
a fresh background `claude --bg` agent seeded with a summary — a different,
simpler shape we did not adopt here).

## What we changed from REMvisual's version

- **Dropped the "beads" dependency entirely.** REMvisual's version assumes a
  `bd` CLI (an issue/task tracker) for chain resolution, claiming tickets,
  and a `bd remember` memory-persistence call. evie-agent has no such tool;
  chain tracking here is keyed off goal/loop-folder slugs (from the
  goals-workflow design and `@evie-agent/coding-agent`'s `loopFolder`
  convention) instead of ticket IDs.
- **Handoffs live next to the work they describe**, not in a single global
  `plans/handoffs/`: a `handoffs/` subfolder of the active goal or loop
  folder, falling back to `.claude/handoffs/` at repo root only when there's
  no active goal/loop folder to attach to.
- **Folded `handoffplan` into `handoff` as a mode** rather than keeping it a
  separate skill, since it's the same mining process with a different
  ending (plan + commit + close vs. just capture).
- **The PreCompact hook** (`hooks/precompact-handoff.sh`) is retargeted the
  same way — no beads, finds the most-recently-modified goal/loop folder
  instead, and is explicitly labeled as a _safety net_ (filesystem/git state
  only) rather than a substitute for the full mining pass this skill does
  when invoked deliberately.
- Line-budget and split thresholds kept as REMvisual specified (they're
  reasonable defaults, not evie-agent-specific), noted in
  `references/validation.md`.

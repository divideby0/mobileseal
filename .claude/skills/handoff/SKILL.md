---
name: handoff
description: Create a structured session handoff so a fresh Claude Code session can pick up immediately — deep conversation mining with self-validation, not a freeform summary. Use whenever work is pausing or wrapping up ("do a handoff", "save session progress", "wrap up for today", "end of day", "pausing for review", switching machines or sessions), when context is running low and there's real conversation history to mine, or before a compact — even if the user never says "handoff".
argument-hint: '[optional reason, e.g. "context low", "end of day", "pausing for review"]'
---

# Session Handoff

Provenance and upstream comparison: `references/attribution.md`. Chain
tracking uses the goal/loop-folder shape this repo already has, not a
separate ticketing tool.

**Guards:**

- **Not plan mode.** This skill writes files. If in Claude Code plan mode,
  exit first.
- **Not shadowing.** Never write a handoff-like document freeform outside
  this skill. Freeform summaries look right but skip chain tracking,
  self-validation, and evidence mining.
- **Not when merely discussing.** Don't create a handoff for questions
  about handoffs ("what does handoff do") or edits to an existing one.
  When work is clearly pausing, wrapping up, or a compact is imminent,
  proceed even without the word "handoff" — that's exactly what the
  description triggers on. If it's genuinely ambiguous whether the user
  wants one created now, ask first.

`$ARGUMENTS` is a soft hint for framing, not a substitute for mining the
actual conversation — extract maximum value before closing, don't just jot
a summary.

## Where a handoff lives

If this session is working a goal or loop folder (see the goals-workflow and
`@evie-agent/coding-agent`'s `loopFolder` conventions), the handoff is a
sibling of that folder's own files — write to
`<goal-or-loop-folder>/handoffs/handoff-<YYYYMMDD-HHmmSS>-<slug>.md`
(datestamp first, matching the draft-folder convention). This
keeps the handoff chain physically attached to the unit of work it
describes, rather than a separate global directory that has to be
cross-referenced by hand.

If there is no active goal/loop folder (exploratory work, not yet drafted
into a goal), fall back to `.claude/handoffs/` at the repo root.

## The PreCompact safety net (one implementation, two wirings)

A PreCompact hook writes an automatic safety-net handoff before Claude
Code compacts context — raw git/goal state plus the `/compact` argument,
not a substitute for this skill's mining pass. The implementation is
`@evie-agent/handoff`'s `precompact` command; there are exactly TWO
sanctioned wirings of it in `.claude/settings.json` (EVA-14), matching
where the repo sits:

- **The evie-agent checkout itself** wires the DIRECT SOURCE PATH —
  `bun packages/handoff/src/precompact-handoff.ts` — deliberately: the
  safety net must fire even in a fresh worktree where `bun install`
  never ran, so it cannot go through node_modules.
- **Every other project** (wired by `evie-agent setup`) invokes the
  linked package by path, anchored on the project root —
  `bun "$CLAUDE_PROJECT_DIR/node_modules/@evie-agent/cli/src/evie-agent.ts"
handoff precompact` (hook commands run through a shell from the
  SESSION's cwd, which may be a subdirectory; the anchor keeps the
  safety net firing regardless) — the source path doesn't exist there.
  NEVER wire bare
  `bunx evie-agent …`: an uninstalled name falls back to the public npm
  registry (dependency confusion — `evie-agent` is not ours there).

Both wirings run the same `run()`; output and location rules above apply
identically.

## Step 1: Gather state

Run in parallel, inline Bash (cheap — never spin up agents for this):

```bash
git log --oneline -20
git diff --stat
git status -s | head -30
git branch --show-current
```

Also: `ls <goal-folder>/handoffs/` (or `.claude/handoffs/`) to find prior
handoffs in this chain.

## Step 2: Chain detection

**Resolve the chain tag:** the goal/loop-folder slug if one exists (e.g.
`ABC-1-some-goal-slug`, or a still-draft
`YYYYMMDD-HHmmSS-{slug}`), else `standalone-<7-char-hex>` (generate
with a quick random-hex one-liner).

**Find the prior handoff in this chain**, two tiers, stop at first match:

- **Tier A — explicit pointer.** Did the user start this session by pointing
  at a specific prior handoff file? That's the parent; read its header,
  continuation seq = parent's + 1.
- **Tier B — folder scan.** `ls <goal-folder>/handoffs/*.md` sorted by
  timestamp — the most recent one is very likely the parent, but **confirm**
  by reading its "Where We're Going" section before claiming continuation:
  is this session's work a direct follow-on of those named next-actions? If
  clearly yes, inherit the chain and increment seq. If unclear or unrelated,
  treat this as seq 1 of a fresh sub-chain and note the sibling file for
  reference only, not as parent. If genuinely ambiguous, ask the user.

No match in either tier: seq 1, parent none.

## Step 3: Read the parent (mandatory if one exists)

If a parent handoff exists, **read it in full** before mining the current
conversation — extract its Goal, Where We Are, Key Decisions, What We Tried,
Where We're Going, Open Questions, and any named identifiers (file paths,
function names, package names). "Since Last Handoff" in the new handoff
requires comparing what was planned against what actually happened.

**Stale-reference check:** grep each identifier named in the parent against
the current codebase. Flag any that no longer resolve — renamed files,
deleted functions, moved packages. This is cheap and catches drift a naive
summary would silently miss.

## Step 4: Mine the conversation

Choose a mining pass based on how much history there is to cover, and
**announce which one and why** before starting — the announcement makes
the choice auditable in the transcript and gives the user their one chance
to upgrade Quick to Deep before mining begins, not after:

| Pass  | When                                | Approach                                                                                                                                                   |
| ----- | ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Quick | Short session, little tool activity | Single pass over the extraction checklist below                                                                                                            |
| Deep  | Long session or many tool calls     | Two passes: first pass captures structure (goals, decisions, files touched), second pass fills in specifics (numbers, exact errors, rejected alternatives) |

**Extraction checklist** (apply per pass — this is where the value is; don't
skim):

- Goal and objective (what this session/goal is actually trying to achieve)
- Work completed — every file modified, with specifics, not just filenames
- Approaches tried, in order — both what worked and what didn't
- Failed approaches and _why_ — the single most expensive thing to
  re-discover if omitted
- Test results and measurements — raw numbers, not "tests passed"
- Decisions made and rejected alternatives, with rationale
- Discoveries and gotchas (the CLAUDE_CODE_TASK_LIST_ID-style surprises)
- Any `CONTEXT.md`/ADR artifacts touched (cross-reference `domain-modeling`)
- Open questions and things explicitly deferred
- Dependencies on other in-flight work (other goals, other worktrees)

## Step 5: Write the handoff

Read `references/output-template.md` for the section structure. Write the
whole thing in **one** `Write` call covering every section — this is the
baseline, not a rough draft to flesh out later.

**Then do a gap pass:** read the file back, scan the conversation again
specifically for anything the first pass under-captured (a table you
skipped, a measurement mentioned without its number, an approach named but
not detailed), and `Edit` it in. Don't skip this pass just because the first
one felt thorough — REMvisual's own evidence is that first passes
systematically under-mine detail.

**Don't duplicate what already exists elsewhere.** If a decision is already
captured in a GOAL.md, an ADR, a Linear ticket, or a commit message,
reference it by path/URL instead of restating it.

**Redact secrets.** No API keys, tokens, passwords, or PII — this document
may itself become a future session's prompt.

## Step 6: Self-validate

Read `references/validation.md` and run every check listed there. If
anything fails, expand the thin section before proceeding — don't hand off a
handoff that fails its own checklist.

Then fill in the handoff's `## Self-Check` section (last section in the
template) — what the trace records, and the honesty rules for writing it,
are specified once in `references/output-template.md`'s Self-Check block;
follow that spec exactly rather than reconstructing it from memory. The
trace is what lets a future reader (or a reviewer of the handoff practice
itself) distinguish a mined-and-verified handoff from a freeform summary
that merely looks like one.

## Step 7: Report

Tell the user, concisely:

- File path and line count
- Chain info (tag, seq, new chain vs continuation, parent link if any)
- Any stale references found in Step 3
- Self-check outcome
- The single most important next action

## Step 8: Ask about closing

> **Handoff complete.** Ready to close this session?
>
> - **Yes** — commit current work, mark the handoff closed, give you a
>   pointer for the next session.
> - **No** — keep working; say "close session" when done.

Default to committing on "yes" unless the user says otherwise.

## Escalation: handoff + plan ("handoffplan" mode)

If the user asks to turn this handoff into an executable plan for the next
session — trigger phrases like "handoffplan", "make this into a plan",
"plan this out and hand off" — read `references/handoffplan.md` and follow
it: the full handoff above still happens first, unabridged; the mode adds
a paired plan file, a surgical commit, a ready-to-paste next-session
prompt, and always closes the session.

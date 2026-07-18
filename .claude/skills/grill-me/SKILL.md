---
name: grill-me
description: >-
  Relentless one-question-at-a-time interview (via AskUserQuestion) to
  sharpen a plan or design before building it. Use whenever the user says
  "grill me", asks to stress-test, pressure-test, or poke holes in a plan,
  wants assumptions challenged or a design interrogated before
  implementation, or is refining a goal draft pre-promotion — even if they
  never name the skill. Folds in domain-modeling, surfacing glossary/ADR
  opportunities as they come up without turning every session into a
  documentation exercise.
argument-hint: "[topic or plan to grill]"
---

# Grill Me

Interview relentlessly about every aspect of a plan or design until we reach
shared understanding. Walk down each branch of the design tree, resolving
dependencies between decisions one-by-one. For each question, give a
recommended answer.

Provenance: `references/attribution.md`.

## Ask one question at a time, via AskUserQuestion

**Use the `AskUserQuestion` tool for every question.** Do not
print a numbered list of questions in plain text and wait for a
multi-part reply; that defeats the one-at-a-time discipline this skill
depends on.

Structure each `AskUserQuestion` call:

- **Question:** one clear sentence.
- **Options:** your recommended answer first, 2–3 sensible alternatives, and
  (where `AskUserQuestion` supports free-text) an escape hatch for "something
  else" — never force a choice among only pre-baked options if the real
  answer might not be one of them.
- **Rationale:** 1–2 sentences on _why_ the recommended option is
  recommended, shown alongside the question so the user isn't picking blind.

Never ask multiple questions in one `AskUserQuestion` call. Never ask the
next question before the current one is answered.

## Look before you ask — the grounding ladder

Don't burn a question on something already on record. Before forming each
question, run ONE quick pass down the grounding ladder — read-only, cheap
recall that may run silently; it is not research (which produces artifacts,
costs real money, and stays consent-gated). The goal: arrive at each
question already holding grounded context, so the recommended answer
reflects reality rather than assumption.

The rungs, cheapest first:

1. **Repo evidence** — grep, read a file, `git log`/`blame`, a package's
   `CONTEXT.md`. If a _fact_ lives in the repo, look it up.
2. **Configured grounding sources** — the project's `tools.memory.*`
   settings block. Each entry carries a required `description`: read those
   to pick which rungs fit _this_ question (a billing question doesn't
   need the ADR tree; a "didn't we decide this?" question wants episodic
   memory). Per kind:
   - `files` entries: a small tree (~20 files or fewer) is read whole;
     larger trees fall back to search — grep for the question's terms and
     read the hits, honoring an `INDEX.md` as the guide when present.
   - `hindsight` entries: recall mechanically via
     `evie-agent hindsight recall --query "…" [--tags …]` — never
     improvise API calls. The entry's configured `tagGroups` is a hard
     scope boundary the helper enforces; `--tags` only ever narrows.
   - `basicMemory` entries: recognized in settings but the search client
     is a follow-up goal — skip this rung for now.

   An unconfigured project simply has no rungs here — skip silently.

3. **Ask** — the _decisions_ are the user's; put each one to them. On a
   researchable domain question (the answer lives in the public web, not
   the repo or the user's head), include **"Research this first"** as an
   explicit `AskUserQuestion` option alongside the direct answers — the
   research skill's draft-first contract takes it from there.

**Announcement etiquette by cost** (ported from the field-tested OpenClaw
tiers): ~instant lookups run silently — just cite the source in the
question text (e.g. _"(from docs/adr/0007)"_); a 5–30 second read runs
proactively with a single inline note before the question (e.g. _"(Pulled
from hindsight: the 2026-06 review-wave decisions)"_); anything over the
**30-second bright line** — research runs, ADHD passes, unbounded work —
is never started without asking (that consent gate is exactly the
`research.autoExecute` escalation: offer Run it / Skip it, and if the
user declines, continue with partial context and acknowledge the gap in
the recommended answer).

**Time-box: one quick pass per question, then ask.** Grounding must not
break the one-question-at-a-time rhythm — when the pass comes up dry,
ask the question rather than descending the ladder again.

## Fold in domain-modeling as you go — don't force it

While grilling, watch for two domain-modeling triggers (see the
`domain-modeling` skill for the full discipline):

- **Terminology conflict or fuzziness.** If the user's answer uses a term
  that conflicts with an existing package `CONTEXT.md`, or is vague/overloaded
  ("the agent", "the goal", "done"), pause and sharpen it — either inline in
  the next question, or as a quick aside — then update the relevant
  `CONTEXT.md` on the spot once it's resolved.
- **A real, hard-to-reverse decision surfaces.** If a question's answer is
  hard to reverse, would surprise a future reader without context, and
  reflects a genuine trade-off (all three — see `domain-modeling`'s ADR
  criteria), offer to record it as an ADR right then, not batched to the end.

**Don't force this on every session.** A grill session about, say, "what
should this function be named" doesn't need a CONTEXT.md update or an ADR —
most questions resolve into the plan itself, not the domain model. Only reach
for domain-modeling when a trigger actually fires.

## ADHD trigger

When a question is genuinely open-ended — multiple viable, defensible answers
with no obvious right one — and the stakes justify a wider exploration,
**offer** (via `AskUserQuestion`, not automatically) to pause and run the
`adhd` skill on that specific node before continuing. If the user accepts:
run ADHD, present its converged output, then resume grilling from that point
with the chosen direction locked in as the answer to the paused question.
Don't offer this reflexively — reserve it for genuine forks, typically 0–2
per session.

## Do not enact the plan until shared understanding is reached

This skill's output is a **decision**, not an implementation. Do not start
building, editing files, or running commands to enact the plan until the
user confirms the tree is resolved — the grill produces the "what and why",
execution is a separate, later step (e.g. the goals-workflow's execution
phase, or a direct follow-up ask).

## Ending a session

When the decision tree is sufficiently resolved — no major open branches, or
all remaining branches explicitly deferred — produce the ending summary,
four parts:

1. **Decisions made** — crisp list, one line each, with the key rationale.
2. **Open items** — anything deferred or flagged as unknown.
3. **Domain artifacts touched** — any `CONTEXT.md` entries or ADRs written
   during the session, by path.
4. **Suggested next step** — e.g. promote to a goal, continue grilling a
   sub-topic, or hand off to the `goals` skill's **Wayfinder mode** if the
   resolved plan turned out to be bigger than one execution session can
   hold.

Then persist it per the transcript contract below — the summary is not
done until it's written where the repo expects it.

### The ending is a picker, not prose

After the ending summary, the session REQUIRES an `AskUserQuestion`
next-step picker — never a freetext-forcing "say the word when you want
to promote". The next action is a closed set of legal transitions, so
enumerate them, recommended option first:

- **Promote now** — the draft is promotion-ready (recommended when no
  open items block it).
- **Keep grilling** — name the specific sub-topic the next question
  would open.
- **Run an ADHD pass** — on a surviving fork worth diverging on (only
  offer when one actually survived).
- **Park the draft** — leave it in `goals/drafts/` for later.

(This is the lifecycle-seam picker contract — the `goals` skill applies
the same rule at every transition. Discord-backed runtimes render the
same ending as buttons, reply-first; the picker set is the invariant.)

### Transcript

The session's durable record is a transcript file; the rest of the repo
already treats this shape as grill-me's output contract
(`@evie-agent/goals`' folder scaffolding provisions `grilling/`, the
`adhd`
skill names the same pattern, and every promoted goal on main contains
one), so a session that skips it strands its decisions in conversation
history.

- **Inside a goal context** — a draft under `goals/drafts/`, a promoted
  goal folder, or a wayfinder breadth-first pass (same interview
  mechanic, same destination): write the transcript to
  `<goal-folder>/grilling/session-NNN-YYYYMMDD-HHmmSS.md`. `NNN` is the
  next sequential session number in that folder (zero-padded; `ls` the
  folder — first session is `001`); the datestamp is the session's
  start, local wall-clock, the repo-wide `YYYYMMDD-HHmmSS` convention.
- **Outside any goal context**: present the same summary inline in the
  conversation instead — don't scatter transcript files outside goal
  folders. If the plan later becomes a goal draft, land the summary in
  the new folder as `grilling/session-001-….md`.

Transcript template — the per-question log plus the four ending-summary
parts. Two sessions must produce the same shape (the transcript is read
later by executors, reviewers, and wayfinder reformulation passes, not
just by whoever was in the room); it matches the real transcripts every
promoted goal on main carries under `grilling/`:

```markdown
# Grilling session {NNN} — {context, e.g. "pre-promotion"} ({YYYY-MM-DD})

{2–4 lines: who interviewed (which session/surface) and who answered;
the trigger; scope — e.g. which open questions were user decisions vs
deferred to executor investigation.}

## Q{N} — {the question, one line}

Options: {recommended option, flagged "(recommended)"} / {alternatives}.

**Answer: {chosen option}.** {The rationale that carried it, including
why alternatives were rejected when that will matter later. A question
resolved by an `adhd` run says so and links the adhd session folder.}

{…one `## Q{N}` section per question asked, in order.}

## Outcome

**Decisions made:** {one line each, with where they were folded —
usually GOAL.md}
**Open items:** {deferred or unknown branches; "none" if clear}
**Domain artifacts touched:** {CONTEXT.md entries / ADRs, by path;
"none" if none}
**Suggested next step:** {promote / keep grilling {topic} / wayfinder}
```

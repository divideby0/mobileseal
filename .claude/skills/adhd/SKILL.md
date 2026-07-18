---
name: adhd
description: Parallel divergent ideation for coding agents, used ONLY while refining a goal (a timestamped draft under goals/drafts/ or a promoted goal folder named for its issue key, e.g. goals/ABC-12-some-slug/) — never as a standalone brainstorming utility. Spawns N isolated branches under different cognitive frames (regulator, biology, speedrunner, 10-year-old, $0 budget), scores, clusters, prunes traps, and deepens top survivors. Use on /adhd, "ADHD mode", brainstorm/ideate intents, or open-ended design, architecture, naming, API/SDK surface, and fuzzy-debugging decisions IF a goal is already active; if there's no goal yet, draft one first (goals skill). Skip for syntax, lookups, bugs with known root cause, or closed phrasing ("quick", "standard", "canonical", "textbook"). Full pre-flight gate (including the goal-context requirement) is in the skill body.
license: MIT
argument-hint: "[the open-ended question or problem to explore]"
---

# ADHD

Stop picking the textbook answer. The first three answers the model would
give are the answers a senior engineer would give in thirty seconds.
Correct. Forgettable. The interesting answers live past number three, in
the awkward middle nobody walks into. This skill makes the model walk
there.

Adapted from [UditAkhourii/adhd](https://github.com/UditAkhourii/adhd)
(`skills/adhd`) — see `references/attribution.md` for what changed.

## Pre-flight (run before Phase 1)

**Step 0. Goal-context gate — checked before anything else, even explicit
invocation.** ADHD only ever runs while refining a goal. It is not a
general-purpose ideation utility invocable on any bare question. Confirm
there is a real `GOAL.md` this run is grounded in — either the active goal
in `goals/drafts/<ts>-<slug>/` or a promoted `goals/ABC-NNN-<slug>/` —
before proceeding. If there is no goal yet (someone wants to brainstorm
before a goal exists at all), the answer is: draft one first (`goals`
skill, Step 1 — takes seconds, it's just a stub `GOAL.md`), then run ADHD
against it. Do not run ADHD against a bare problem statement with no
`GOAL.md` to ground it, even if explicitly asked to via `/adhd <question>`
— say so and offer to draft the goal stub first instead. This gate exists
because every ADHD run needs somewhere real to write its session folder
(`{goal-subfolder}/adhd/session-NNN-YYYYMMDD-HHmmSS/`, see "Directory
conventions" below) and something real to ground branches in beyond a
free-text string (`--goal-file`/`--reference`, read by the frame sessions
themselves — see `write-frame-prompts.ts`).

This skill is expensive. About 10 branch calls, 30–90 seconds wall clock
under the default `local-subagents` strategy (minutes under the
`multiplexer` mode — see Branch execution below for how it's chosen), 5–10x
a single answer at minimum. Do not pay that cost when a direct answer is
better. Run the rest of this gate before Phase 1.

**Step 1. Explicit invocation check.**

If the user typed `/adhd` or explicitly asked for ADHD mode, "use the adhd
skill", or "run ADHD on this" **and Step 0's goal-context gate passed**,
**SKIP the rest of this section and go straight to Phase 1**. The user
opted in. Do not second-guess. This also covers being invoked _by_ another
skill's own ADHD trigger (e.g. `grill-me` pausing mid-interview on a
genuinely open fork, or the `goals` skill's own ideation step) — that's
already the explicit-opt-in case, just routed through a different skill,
and it's inherently goal-scoped since both callers only ever operate
inside a goal's own refinement phase.

**Step 2. Self-judge (only if Step 1 did not match).**

Ask yourself four questions. If the answer to any of the first three is
no — or to the fourth is yes (already converged) — ABORT.

1. **Open-ended?** Would a senior engineer give multiple viable answers
   here, or is there one canonical answer? If canonical, abort.
2. **High-stakes?** Is the cost of the obvious answer being wrong actually
   high? Architecture decisions, public API surfaces, naming a real
   product, fuzzy bugs with no known root cause, schema design = yes.
   Side project at 11pm = no.
3. **Open phrasing?** Did the user avoid words like "quick", "standard",
   "canonical", "textbook", "just", "one-line"? If they used any of those,
   they want the direct answer. Abort.
4. **Already converged?** (Adaptation over upstream.) If this question already
   went through a `grill-me` session and reached a locked decision, don't
   re-run ADHD against it after the fact to relitigate — that's sunk-cost
   ideation against settled ground, not genuine exploration. ADHD belongs
   _before_ or _during_ convergence on a specific still-open fork, not
   applied wholesale to a design that's already been decided.

If all checks pass, proceed to Phase 1.

If any fails, ABORT and answer the question directly. Optionally append one
sentence: _"If you want a wider exploration under parallel cognitive frames
with explicit trap detection, run `/adhd <your problem>`."_

## Branch execution: three real modes, chosen by project config

Three genuinely different, all-valid ways to run Phase 1/Phase 2 branches
exist, empirically verified across three spikes (not speculative — see
`research/adhd-spike-findings-index.md` at the repo root — "the spike
index" below — for all of them):

1. **Local subagents** (`Task`/`Agent` tool calls, matching the upstream
   skill exactly). Cheapest, fastest (seconds), but only **sequentially**
   observable while running — CC's own in-pane picker (`↓` to select,
   `Enter` to view) lets you watch one branch's live transcript at a time,
   never all of them simultaneously. Fine when nobody needs to watch the
   frames reason in real time, only read the converged output after.
2. **Multiplexer, layout=tabs, backend=herdr** — one real `claude` process
   per frame, each in its own herdr tab, all **simultaneously** running and
   individually steerable, one full-screen view at a time (flip between
   tabs rather than reading a packed grid). **This is the recommended
   multiplexer configuration** — confirmed live that splitting panes side
   by side gets cramped and hard to read past 2–3 frames (see
   the spike index, Round 7); tabs avoid that
   entirely since each one gets the full pane area.
3. **Multiplexer, layout=panes, backend=herdr** — same as (2) but each
   frame gets a split pane within one tab instead of its own tab, all
   visible in a grid at once without needing to flip. Available as an
   explicit opt-in (`adhd.layout: panes`) for anyone who specifically wants
   the packed-grid view despite the crowding — e.g. 2 frames, or a wide
   enough terminal that a 2–3-way split still reads fine — but is no
   longer the default `layout` value (see below).

**Which one runs is project config, not a hardcoded default in this
skill, and it's THREE separate settings, not one combined strategy
string.** Read from the layered `.evie-agent/settings.*` surface (e.g.
`.evie-agent/settings.yaml`, the same settings the `goals` skill's
review-tool selection reads from — see the goals skill's
`references/review-waves.md`, "Configurable mechanisms"):

```yaml
adhd:
  branchExecution: local-subagents | multiplexer | none
  multiplexer: herdr # only read when branchExecution: multiplexer
  layout: tabs | panes # only read when branchExecution: multiplexer
```

Split into three keys instead of one `paneStrategy: herdr-panes|herdr-tabs`
string specifically so a future non-herdr multiplexer backend (a
hypothetical `tmux`-native or `iterm2`-native equivalent) can be added
later as a new `multiplexer` value without inventing a whole new parallel
set of `<backend>-tabs`/`<backend>-panes` strategy strings — `layout`
stays the same backend-agnostic concept regardless of which multiplexer
implements it.

`branchExecution` defaults to `local-subagents` when unset (matches the
upstream skill's original design, cheapest/fastest). `multiplexer`
defaults to `herdr` (the only backend implemented so far) when
`branchExecution: multiplexer` is set but `multiplexer` itself is omitted.
`layout` defaults to `tabs` (the recommended, uncrowded default) when
`branchExecution: multiplexer` is set but `layout` is omitted. `none`
disables ADHD entirely for that project — the pre-flight gate should abort
immediately, same as a failed self-judge check. If a project has no
settings file, or the file doesn't set `adhd.branchExecution` at all,
fall back to `local-subagents`.

**Never fall back silently.** When the resolved mode is `local-subagents`
because no settings file (or no `adhd.branchExecution` key) was found — not
because the user or project explicitly chose it — say so out loud before
spawning branches, in one line: e.g. _"No `adhd.branchExecution` set in
this project — running frames as local subagents (fast, but only one
branch's transcript is viewable at a time, via ↓/Enter). Set
`adhd.branchExecution: multiplexer` (with `multiplexer: herdr`,
`layout: tabs`) in `.evie-agent/settings.yaml` for simultaneous,
independently-viewable frames instead."_ A user watching the transcript
should never have to already know this knob exists to find out it was
available. This is separate from and in addition to the pre-flight gate's
own messaging (Step 0/1/2 there govern whether ADHD runs at all; this
governs how, once it's running).

**Escalating a single branch outside the chosen strategy** is still valid —
e.g. under `local-subagents`, one Phase 2 deepen branch that stops being
pure ideation and wants to actually prototype real code should still be
spun out as its own real session (possibly its own goal folder), not
silently folded into the ADHD loop's branch count. Say so explicitly in the
Converge/Focus output rather than quietly switching execution strategy
mid-run.

### Under `branchExecution: multiplexer`: read the runbook first

When the resolved mode is `multiplexer`, read
`references/multiplexer-execution.md` before spawning anything — it is a
mandatory runbook (the three `evie-agent adhd …` script invocations with exact
command lines, script resolution outside this repo, the manifest.json
shape, and the `acceptEdits` launch rationale), not background reading.
The mechanics are scripted because improvising them has failed live twice
— uneven pane splits, `-p` sessions that exit instead of staying open,
frames stalling on permission prompts (see the spike index, Round 7). If
you find yourself typing a raw `herdr pane split` or `herdr tab create`
call for ADHD branch execution, stop: that means the runbook was skipped.
Frame _selection_ stays your judgment call — only the mechanics are
scripted.

### Directory conventions

ADHD never writes outside a goal folder (Step 0's gate). Every run lives
under that goal's own `adhd/` subfolder, one numbered+timestamped session
per run, one subfolder per frame within it:

```
{goal-subfolder}/
  GOAL.md
  references/
  grilling/
  adhd/
    session-NNN-YYYYMMDD-HHmmSS/
      manifest.json              # written by spawn-frames.ts
      10-year-old/
        prompt.md                # written by write-frame-prompts.ts
        output.json              # written by the frame session itself
      game-design/
        prompt.md
        output.json
  results/
  reviews/
```

`NNN` is a sequential counter local to that goal's `adhd/` folder (`001`,
`002`, ...) — a goal can run ADHD more than once across its refinement
(e.g. once on the overall shape early, again later on one still-open
fork), and each round gets its own numbered session rather than
overwriting or nesting inside the previous one. Same `session-NNN-
YYYYMMDD-HHmmSS` shape as `grilling/session-NNN-YYYYMMDD-HHmmSS.md`
elsewhere in the goal folder — both are sequential-counter + timestamp,
kept consistent across both subfolders.

### Why prompts and outputs go to files, not inline text

Under every branchExecution mode: each frame's exact prompt is written to
`<runDir>/<frameId>/prompt.md`, and each frame is instructed to write its
JSON output to `<runDir>/<frameId>/output.json` in that same per-frame
subfolder — never just replying inline in a subagent/session transcript.
This makes every branch's exact instruction and exact result independently
auditable after the fact (open the file, see precisely what that branch
was told and what it produced) and makes result collection mechanical
(read a file, don't scrape a transcript) rather than dependent on scraping
conversational text out of a possibly-still-scrolling pane.

## The loop

Two strict phases. Mixing them kills idea quality, because the critic
strangles the generator.

### Phase 1 — Diverge (no critic)

For the problem P:

1. Pick 5 cognitive frames from the table below. Bias toward engineering
   tags when the problem is code-shaped. Always include at least one wild
   frame to keep range.

2. Spawn 5 **parallel** branches using whichever mode `adhd.branchExecution`
   selects (see Branch execution above: local subagent calls, or real
   interactive `claude` processes under the `multiplexer` mode). One per
   frame. Each branch gets only:
   - the problem P
   - any context the user provided
   - the goal artifacts passed via `--goal-file`/`--reference` (this
     goal's `GOAL.md`, plus whichever specific `references/` entries are
     relevant to this fork — see Step 0 and `write-frame-prompts.ts`)
   - the chosen frame's vantage prompt
   - a system instruction that forbids evaluation

   The exact instruction to give each branch:

   > You are in DIVERGENT mode. You are a generator, not a critic.
   > Generate 6 short distinct ideas under this frame. Each idea is one
   > phrase or one sentence. Do not evaluate. Do not rank. Do not hedge.
   > The first three obvious answers everyone would give are banned.
   > Push past them into the awkward middle.
   > Output a JSON array only. No prose before or after.
   > `[{"text": "...", "rationale": "..."}, ...]`

   Under `multiplexer` mode, this instruction is the follow-up message
   sent into each pane/tab's already-running interactive `claude` session
   — never a `-p`/`--print` invocation argument (see the hard warning in
   `references/multiplexer-execution.md`).

3. **Critical invariant.** The branches must be parallel and isolated. Do
   NOT serialize them. Do NOT pass one branch's output as context to
   another. Branches that see each other anchor each other and the whole
   method collapses to a wider single thought. This holds regardless of
   branchExecution mode — multiplexer panes/tabs are just as capable of
   being wired up to
   accidentally share context (e.g. by seeding one pane's prompt with
   another pane's partial output) as subagents are of being serialized;
   the invariant is about information flow, not the execution mechanism.

### Phase 2 — Focus (critic on)

After all branches return:

1. **Score.** Rate each idea on three axes 0 to 10: novelty (distance from
   the obvious default), viability (could it actually ship), fit (does it
   address the stated problem). For any idea that looks attractive but is
   a trap (hidden cost, false economy, will not scale, premature
   abstraction), flag it with a one-line reason.

2. **Cluster.** Group ideas into 3 to 6 clusters by their underlying angle,
   not by surface keywords. Label clusters by angle: "remove the server
   plays", "cache-shaped plays", "batched-window plays", "race-multiple-
   backends plays".

3. **Deepen the top 3.** Rank by weighted score (novelty 0.35 + viability
   0.40 + fit 0.25), exclude traps, take top 3. For each, spawn one branch
   (same strategy as Phase 1, or escalate a specific branch outside the
   project's normal strategy — see Branch execution above — if that one
   idea genuinely needs real prototyping to evaluate) that produces:
   - a 4 to 8 sentence sketch of how the idea works
   - the load-bearing risk
   - the first concrete step a builder would take
   - 3 to 5 child ideas (variations, hybrids, unlocks)

   Deepen subagent instruction:

   > You are in FOCUS mode. Take one promising idea and connect dots.
   > Sketch how it would actually work in 4 to 8 sentences. Name the
   > load-bearing risk. Name the first concrete step a coder would take.
   > Then generate 3 to 5 sub-ideas that branch off (variations,
   > combinations with other domains, things this unlocks).
   > Output JSON only, exactly this shape:
   > `{"sketch": "...", "risk": "...", "first_step": "...", "children": ["...", "..."]}`

## Frames

Pick 5 per run.

| Frame                                  | Vantage prompt                                                                                                                                                        | Tags                  |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| **hardware engineer**                  | You think in latency, memory layout, and physical constraints. Re-ask this as a hardware/firmware problem. What does the bus topology, cache, timing budget tell you? | code, wild            |
| **regulator**                          | You audit systems for compliance and failure modes. What must be provable, traceable, or refusable here?                                                              | design, general       |
| **10-year-old**                        | You are a curious 10 year old who has never seen software. Describe naive but unencumbered approaches. Ignore convention.                                             | general, wild         |
| **competitor trying to break it**      | You are a hostile competitor or attacker. Generate approaches that exploit, fail, or sabotage the obvious solution. Then invert into ideas.                           | code, design          |
| **biology**                            | Transplant a mechanism from biology (immune systems, neural plasticity, cell signaling, evolution, gut flora). Force-fit it onto this engineering problem.            | code, wild            |
| **logistics**                          | Steal mechanisms from logistics: queues, batching, just-in-time, hub-and-spoke, returns, last-mile. Apply them literally.                                             | code, design          |
| **game design**                        | Approach this as a game designer. What are the loops, rewards, friction, save-states, speedrun tricks? Treat the user as a player.                                    | design, general       |
| **markets**                            | Treat the problem as a market. Buyers, sellers, market-makers. What does an auction, a futures contract, a clearing house look like here?                             | design, wild          |
| **inversion**                          | Ask the OPPOSITE question. If goal is X, brainstorm how to guarantee NOT X. Then negate each answer back.                                                             | code, design, general |
| **extreme: $0 budget, 1 hour**         | No money, no team, one hour. What is the crudest version that still does the load-bearing thing?                                                                      | code, general         |
| **extreme: infinite budget, 10 years** | Infinite compute, infinite engineers, a decade. What is the maximalist version?                                                                                       | design, wild          |
| **remove the load-bearing assumption** | Name the thing everyone treats as fixed (framework, database, request-response model, network). Imagine it is gone. What is possible?                                 | code, design, wild    |
| **speedrunner**                        | You are a speedrunner. Find glitches, skips, out-of-bounds tricks, frame-perfect shortcuts. What is the abusive-but-legal path?                                       | code, wild            |
| **ant colony**                         | No central planner. Many dumb agents, local rules, pheromone trails. How does the problem solve itself emergently?                                                    | code, wild            |
| **3am on-call**                        | You are the on-call engineer woken at 3am when this breaks. What design would let you not get paged?                                                                  | code, design          |

### Picking frames

For code-shaped problems: pick 4 frames tagged `code` or `design`, plus 1
tagged `wild`. For open product or strategy problems: a mix from all tags.
Vary the picks across sessions so the same problem produces different
candidate sets when re-run.

## Output shape

After Phase 2, render in this order. Do not collapse it into a wall of
prose. The structure is the point.

1. **Brief.** One or two lines confirming the problem and any reframe used.
2. **Wide set.** Full pool grouped by cluster. Each cluster labeled by
   underlying angle. Each idea is one short phrase. Show score chips like
   `[N7 V8 F9]` next to each.
3. **Converge.** A 2 to 4 idea shortlist. State why each is on the list.
   Mark the non-obvious-but-viable pick explicitly with ★. List traps
   separately, each with the one-line reason it is a trap.
4. **Focus.** The 3 deepened branches. For each: the sketch, the load-
   bearing risk, the first concrete step, and the child ideas.
5. **Provocation.** One wildcard question or idea that opens a new
   direction the user can push into if nothing landed.

## Anti-patterns

These are how this skill goes wrong. Watch for them.

- **Convergence disguised as divergence.** Ten minor variations of one idea
  is not breadth. If every candidate shares the same underlying assumption,
  you have not diverged. You have decorated.
- **Weird-for-weird's-sake with no convergence.** A pile of 30 unsorted
  absurdities is as useless as one safe answer. Always converge.
- **Walls of equally-weighted prose.** Cluster, label, pull out the best.
  Structure is half the value.
- **Refusing to commit.** After diverging, take a position on what is
  actually promising. "Here are 20 ideas, you decide" is a cop-out.
  Generate wide, but converge with a real opinion.
- **Skipping the isolation invariant.** If you simulate parallel branches
  by writing them sequentially in one context, you have not done ADHD. You
  have done a wider single thought. Use real parallel, isolated subagent
  calls.
- **Re-running against a converged decision.** (Adaptation over upstream.)
  Running ADHD against a question `grill-me` already resolved isn't
  divergence, it's relitigating — see pre-flight Step 2.4.

## Calibration

- **How many ideas?** Scale to stakes. Quick "name this function" =
  3 frames × 4 ideas. "How should I position this product" = 5 frames ×
  8 ideas. Default is 5 × 6 = 30.
- **How weird?** Read the room. Serious strategy work: flag the wild cards
  clearly so they do not read as unserious. Open brainstorming or play:
  let it run loose. Absurd ideas earn their place by seeding viable ones.
- **When to stop diverging?** Stop when new candidates start repeating the
  shape of existing ones. The space is mapped. Do not pad to hit a number.

## Cost

5 diverge + 1 score + 1 cluster + 3 deepen ≈ 10 branch calls per run. Cost
shape depends on `adhd.branchExecution` (see Branch execution above):
`local-subagents` keeps this at local-subagent cost throughout (seconds
each, the upstream skill's original ~30–90s wall clock estimate holds).
`multiplexer` mode carries real per-process setup and session cost for
every branch, not just an escalated one — budget minutes, not seconds, and
expect the pre-flight gate's cost/benefit framing to weigh more heavily
toward "is this worth it" when that mode is configured. An individual
branch escalated outside the project's normal mode (e.g. one deepen branch
that needs real prototyping under an otherwise `local-subagents` project)
carries its own cost in isolation — not the whole run's.

## Relationship to `grill-me` and `goals`

ADHD is not invoked standalone as a first move in most cases here — it's
usually pulled in by `grill-me`'s own "ADHD trigger" (offered, never
automatic, when a specific question in an interview is genuinely
open-ended with no obvious right answer) or directly by the `goals` skill's
ideation step for a whole draft goal that's wide open. Either way: converge
on that one fork's output, then resume the calling context (interview
question answered, or goal draft updated) with the chosen direction locked
in — ADHD's own output is an input to convergence elsewhere, not a
terminal artifact by itself.

## Source spec

This skill operationalises a written spec on divergent ideation from the
upstream project. See `references/attribution.md` for the source and what
changed in this adaptation.

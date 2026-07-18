---
name: goals
description: The goal lifecycle for this repo — draft an idea, refine it, promote it to Linear, execute it via a herdr-driven Claude Code session, gate completion on a blind multi-tool review, and lock it. Includes wayfinder-mode planning for ideas too big for one execution session. Use for ANY new feature, fix, or piece of work that will eventually touch code — even small fixes, and even when the user never mentions goals or Linear, since nothing gets built in this repo outside a goal. Also use to check on a goal or its review wave ("is the review for ABC-7 done?"), or to resume or execute an already-promoted goal. /goals is a stateful door — bare /goals lists open goals (the save-select), /goals draft plus a description runs capture-first intake into a working draft, /goals completed pages locked goals.
argument-hint: "[draft <description> | completed | <goal name>]"
---

# Goals

The lifecycle for anything that eventually needs to get built in this repo.
An idea starts as a loose draft, gets sharpened through interview (and
sometimes wider exploration), is promoted to a real tracker issue (Linear or
GitHub, per the project's `tools.tracker.*` block) once it has
solid footing, executes as a herdr-driven Claude Code session, and is
gated on a blind multi-tool review before it locks permanently. Nothing gets
built in this repo except through a goal — this is deliberate: it's the one
path, not one of several.

Adapted from the goals-workflow design worked out in the evie-agent
repo's EVA-1 goal record (its `GOAL.md` is this skill's source spec;
its grilling transcript holds the full design rationale — decision
provenance throughout this skill cites such `EVA-N` goal records), with its
planning-for-oversized-work mode adapted from
[mattpocock/skills](https://github.com/mattpocock/skills)'
`skills/engineering/wayfinder`, retargeted onto a local-file-tree map that
rolls forward goal-by-goal (upstream's tracker-canonical mode is a deferred
per-project config option; tracker issues are created lazily). See
`references/attribution.md`.

## Roles, not products ("the agent")

Every reference to "the agent" in this skill and in anything it generates
means _whoever is directly driving right now_ — this could be OpenClaw
orchestrating from Discord (thin: it delegates the actual token-intensive
work down into spawned Claude Code sessions via herdr rather than doing it
inline) or a Claude Code session itself, paired directly with the user over
a shared herdr/tmux pane. Both surfaces support the same verbs — draft a
goal, run an interview, check review status, chart a map — without
functionality loss. Where OpenClaw would use an interactive Discord
component, a standalone Claude Code session uses its native
`AskUserQuestion` tool as the equivalent primitive. Refer to "the
orchestrator" (cost-averse, always delegates execution) and "the executor"
(the Claude Code session actually doing plan+execute work) rather than
"OpenClaw" or "Claude Code" by product name, so a goal file dropped into a
fresh session has no dangling references.

## The `/goals` door (EVA-13)

`/goals` is ONE stateful door, not a verb family: what it does is picked
by the detected lifecycle state of wherever it was invoked. Probe state
FIRST, before choosing any behavior:

```bash
bun node_modules/@evie-agent/cli/src/evie-agent.ts goals context
```

(`detectGoalContext` — pure, resolved from cwd + branch against the goal
surface). An ambiguous probe — cwd and branch disagreeing, an unreadable
GOAL.md — **degrades to the save-select screen: ask, never guess a
verb.** The same package commands back every door behavior (`evie-agent
goals list | completed | context | draft` is the shell mouth; this skill
is the in-session mouth — same verbs, one throat).

**Bare `/goals`** — the save-select screen. Render `evie-agent goals
list`: OPEN goals only — active drafts (title, open-question count,
last-touched) and promoted/executing goals (lifecycle state) — ordered
by promotion timestamp newest first (drafts, having none, by created
timestamp, in the same ordering). Then ask ONE fixed-shape
AskUserQuestion regardless of goal count — _Start a new goal / Refine an
existing one (name it next) / Just checking_ — and STOP. Selecting an
existing goal happens BY NAME in the next turn; never enumerate goals as
AskUserQuestion options (options cap at 4 — the list itself is the
picker).

**`/goals draft [description]`** — the ONE canonical intake verb (no
`new`/`create` alias anywhere; the whole system speaks "draft").
Bare `/goals draft`: ask for the description next turn. With a
description, run intake:

1. **Classify** (`classifyIntake` — hybrid creation timing): a clean
   work item creates immediately; a question-shaped, exploratory, or
   too-thin description gets ONE confirmation turn — echo a one-line
   understanding and ask it as a PICKER (_Create the draft / Just
   thoughts, don't create / Let me rephrase_), never a typed "yes".
   When in doubt, confirm: a lost turn is cheaper than branch litter
   from a misread question.
2. **Capture first** (`captureIntake`, or `evie-agent goals draft
--slug … --title … --description-file …`): `startDraft` scaffolds
   branch + mirror worktree, and the description lands BYTE-FOR-BYTE as
   `references/intake.md` before any interpretation. Pick the slug and
   the verb-prefixed Title Case title yourself from the description.
3. **Distill provenance-honestly** into GOAL.md (inside the draft's
   worktree): never silently invent specifics — keep derived content
   distinguishable from agent-inferred content, and park everything
   vague in an "Open questions (for grilling)" section. A vague dump
   that yields an EMPTY open-questions section is a failure signal, not
   a success.
4. **Flow DIRECTLY into the grill** (`grill-me`) — a freshly drafted
   goal gets its first grill question immediately, with no "want to
   start the grill?" offer in between (EVA-19, superseding EVA-13's
   end-by-offering: the offer turn was a wasted turn — escape is native
   at any question). The intake path remains structurally incapable of
   promotion — it imports no Linear/promote code (contract-tested) — so
   promotion stays an explicit, separate, user-triggered act.

Wayfinder is an **escalation, not the default**: intake produces a plain
draft; suggest wayfinder mode only when the description is genuinely
oversized (the existing judgment call, made during refinement — see
Wayfinder mode below).

**`/goals completed`** — the locked-goals view: newest-completed first,
**paged at 10** (`evie-agent goals completed [--offset N]`) with a
"show older" affordance in the next turn — never the unbounded list.

**Other intents** (`promote`, `execute`, `status`, a goal name) are
validated against the detected state: legal intents fast-path into the
lifecycle steps below; illegal ones explain what would make them legal
(e.g. `promote` on a locked goal → "locked goals never reopen; draft a
new goal referencing it"). Unknown intents (`/goals new`) get a
did-you-mean naming the canonical verb — the teaching-moment pattern,
same as the CLI's.

**Discoverability note**: Claude Code has no subcommand autocomplete
(verified 2026-07-13 — `/` filters command names; arguments are free
text; `argument-hint` is displayed, never completed). The door's own
behaviors ARE the discoverability: bare `/goals` is the menu, the
`argument-hint` documents the verbs, did-you-mean catches typos.
Revisit hyphenated per-verb commands only if the verb family outgrows
~4.

## Lifecycle seams are pickers (EVA-19)

**Principle: pickers for legal transitions, freetext for design,
autonomy for operations.** Wherever the next action is a CLOSED SET of
legal transitions, end the turn with an `AskUserQuestion` picker
enumerating them, recommended option first — never prose like "say the
word" or "say execute when you want it launched", which forces the user
to type a magic phrase the options could have carried. (Discord-backed
runtimes render the same seams as buttons, reply-first — the picker set
is the invariant; the widget is per-runtime delivery.)

The seams, with their canonical option sets:

- **Hybrid-intake confirmation** — _Create the draft / Just thoughts,
  don't create / Let me rephrase_ (see intake step 1; never a typed
  "yes").
- **Post-intake** — the EXCEPTION: no picker, no offer. A freshly
  drafted goal flows directly into the first grill question (intake
  step 4); escape is native at any question.
- **Grill ending** — _Promote now / Keep grilling (name the sub-topic)
  / Run an ADHD pass / Park the draft_ (owned by `grill-me`'s ending
  contract).
- **Post-promotion** — _Execute now / Review on the issue first /
  Hold_.
- **Post-wave** (after INDEX.md reconciliation, when the wave is the
  user's to act on) — _Fix the merged findings / Run another wave /
  Accept and proceed to completion_.
- **Wayfinder escalation** (drafting reveals an oversized idea) —
  _Chart a wayfinder map / Keep it one goal anyway / Split it manually_.
- **Unisolated-launch refusal** (`startGoalExecution` refuses: the
  project makes no worktree-isolation assertion while another goal is
  executing) — _Wait for the running goal / Override accepting the risk
  / Implement the environment hook_.
- **The merge moment** (post-completion, after PR verification) —
  _Merge now / Review the PR first / Hold_.
- **Post-lock verification failure** (a locked goal's claim doesn't
  hold up) — _Send back to the executor (new goal) / Accept with a
  recorded caveat / Investigate together_.
- **Watcher dead-ends** (an executor unresponsive after a SECOND failed
  nudge) — _Kill and relaunch / Keep waiting / Inspect the session
  together_.

Explicit NON-pickers — where a picker would be wrong:

- **Wave failures and INDEX.md reconciliation** are the executor's
  judgment: merged findings are decided and RECORDED, never put to the
  user as a vote.
- **Open design discussion** — freetext is correct; don't flatten a
  genuinely open question into four options (grill-me's own escape
  hatch exists for exactly this).
- **The-list-is-the-picker** — never enumerate goals as
  `AskUserQuestion` options (options cap at 4); render the list, ask
  the fixed-shape question, selection happens by name.
- **Autonomous executors don't ask at all**: an executing session that
  reaches its gates doesn't ask "should I lock?" — the completion
  sequence (RESULT.md → frontmatter → commit → push → stop) IS the
  answer; the merge-moment picker belongs to the orchestrator/user
  conversation afterward.

## Estimate in relative effort, never calendar time (EVA-21)

Anywhere a goal (or its workstreams) gets sized — drafting, grilling,
scope discussions, sequencing notes — the estimate is **relative
effort**, expressed as t-shirt sizes on a Fibonacci scale:

**XS=1, S=2, M=3, L=5, XL=8, XXL=13.**

Never human/calendar time: "8–12 weeks" is meaningless when a goal
executes in ~30 minutes of agent time, and it silently smuggles in
human-team assumptions (meetings, handoffs, review latency). Relative
size and risk are what an estimate must carry; wall-clock is not.

The scale is FIXED — documented here, not settings-configurable — a
shared vocabulary across goals, research reports, and wayfinder maps
is the point. The same rule binds research report sizing (the research
skill) and wayfinder ticket/map sizing (`references/wayfinder.md`).

## Directory conventions

```
{PROJECT_ROOT}/
  goals/
    drafts/
      YYYYMMDD-HHmmSS-{goal-slug}/
        GOAL.md                # frontmatter + spec; this file's shape
        references/            # goal-specific context, progressive disclosure
          INDEX.md
        grilling/
          session-NNN-YYYYMMDD-HHmmSS.md
        adhd/                  # ONLY ever runs during goal refinement —
                                # see adhd/SKILL.md pre-flight Step 0
          session-NNN-YYYYMMDD-HHmmSS/
            manifest.json
            {frame-name}/
              prompt.md         # includes references to this goal's own
                                 # GOAL.md / references/ — never a bare
                                 # free-text problem statement
              output.json
        results/
          RESULT.md             # written once the goal is actually executed
        reviews/
          wave-NNN/              # per-goal sequential (wave-001, …);
                                 # pre-EVA-21 goals have datestamped
                                 # review-YYYYMMDD-HHmmSS/ instead
            INDEX.md             # merged summary across tools
            claude-code/
            codex/
            sonarqube/
            coderabbit/
        handoffs/                # session handoffs (handoff skill + PreCompact hook)
        wayfinder/               # only when this goal is a step on a map:
          MAP.md                 # the CURRENT map — destination, decisions
          references/            # so far, fog, ticket definitions —
                                 # recrafted forward into the next goal;
                                 # see Wayfinder mode
    ABC-NNN-{goal-title-slug}/   # promoted goal — same shape, moved+committed
  research/                      # project-level, shared across goals (NOT under goals/)
```

`goals/drafts/<ts>-<slug>/` is tracked from the start: creating a draft
creates a branch named after the draft folder (e.g.
`draft/YYYYMMDD-HHmmSS-{goal-slug}`) **born directly into its own
worktree** — the primary checkout never leaves main. Drafting-phase edits
are committed to that branch as they land, inside the worktree. At
promotion the _entire folder_ moves to `goals/ABC-NNN-{slug}/` (using the
real issue key) via `git mv`, the branch is renamed to match the issue
key (`git branch -m`; if already pushed, push the new name and delete
the old), **and the worktree moves with it** (`git worktree move`).
Nothing is copied. That same branch — and that same worktree, which the
execution handoff adopts — then carries execution (step 5), so a goal's
record lands on main when its execution branch merges — always via a
real merge commit, never a squash, so the commit hashes baked into
Linear permalinks stay reachable from main.

### Worktree layout (path-mirror invariant)

Every goal lives in exactly one worktree across its whole life, and at
every lifecycle stage the worktree path is `.worktrees/` + the goal
folder's path relative to `goals/`:

```
.worktrees/
  drafts/
    YYYYMMDD-HHmmSS-{slug}/   # draft — mirrors goals/drafts/<ts>-<slug>/
  ABC-NNN-{slug}/             # promoted onward — mirrors goals/ABC-NNN-<slug>/
```

`ls .worktrees/drafts/` **is the draft backlog surface**: every active
draft sits there with its full GOAL.md on disk (there is deliberately no
separate index file to keep in sync); undrafted candidates stay in locked
goals' RESULT follow-up sections. Worktrees are LOCAL state — they exist
on the machine that created them, not in git.

**Lifecycle end — remove on merge**: a goal's worktree is removed once
its branch is merged to main (`removeMergedGoalWorktree`) — locked +
merged means everything in it is reachable from main and the worktree is
dead weight. Hard guard: **never remove a worktree whose branch is not
an ancestor of main**; removal is non-force, so git refuses a dirty
tree. An abandoned draft's worktree goes when its branch is deleted
(manual, deliberate) — and abandoning a goal whose waves ran sonar
also means deleting its ephemeral `<projectKey>-<branch>` sonar project
(`deleteSonarBranchProject`), which otherwise accumulates on the
server; merge cleanup handles this automatically only for merged
goals.

## Frontmatter lifecycle (on `GOAL.md`)

```yaml
status: draft | promoted | started | completed
created: <ISO 8601>
promoted: <ISO 8601> # set at promotion
issue_url: <url> # set at promotion (tracker issue link)
started: <ISO 8601> # set when a coding-agent session is launched against this goal
completed: <ISO 8601> # set ONLY by the executing agent (together with status: completed), once the goal's green gates pass
stacked_on: ABC-7-parent-slug # optional — the unmerged parent branch this goal stacks on (see Stacked goals)
```

Frontmatter keys are always **snake_case** (`issue_url`), never camelCase.
A legacy `resources:` key (EVA-11's declared-resource ledger, superseded
by EVA-24's environment hook — see Concurrent goals) is tolerated and
ignored wherever it still appears in locked goals: never author it, never
error on it.

`completed` is the single source of ground truth for "is this goal done."
Everything else (herdr `done`/`idle` state, `.done` files from
non-interactive reviewers, a detached process noticing a pane went quiet) is
a _signal that something should go check_, never itself proof of completion.
A goal whose frontmatter has `completed` set is **locked** — hard rule, no
reopening, no resuming: the locked folder is the immutable record that
commit-pinned Linear permalinks, later goals' references, and rolled-forward
wayfinder maps are all built against, so editing it would silently rewrite
history other artifacts already cite (`GoalLockedError` enforces this in
every package write path). A bug found after completion produces a new goal
that references the old one; it does not reopen the old one.

## Lifecycle

1. **Draft.** User describes an idea (to OpenClaw, or directly inside a
   Claude Code session — both are first-class). Create the draft via
   `@evie-agent/goals`' `startDraft` (invocation example below): it
   creates `draft/<ts>-<slug>` from main directly into a worktree at
   `.worktrees/drafts/<ts>-<slug>/` (path collision → error), scaffolds
   `goals/drafts/<ts>-<slug>/GOAL.md` inside it, commits, and pushes —
   the primary checkout must be on main and never switches off it.
   (`createDraft`/`scaffoldGoalFolder` remain the pure-filesystem
   primitives underneath, adapting `@evie-agent/coding-agent`'s
   loop-folder shape to this directory layout.) The GOAL.md body that
   drafting fills in follows `references/templates.md`. All refinement
   (step 2) happens inside the draft's worktree.
2. **Ideation / refinement.** Any combination of: `grill-me` (one-question-
   at-a-time interview, domain-modeling folded in), `adhd` (parallel
   cognitive-frame branches, grounded in this goal's own `GOAL.md`/
   `references/` — ADHD never runs outside a goal's refinement phase, see
   `adhd/SKILL.md` pre-flight Step 0; execution mode — local subagents vs.
   real multiplexer panes/tabs — is project config, see
   `adhd.branchExecution` in `references/review-waves.md`'s settings
   surface, not a fixed choice), the `research` skill
   (`evie-agent research …` — draft-first, needs explicit go-ahead
   before executing; artifacts land at the project's configured
   `storage.research` destinations — local drafts under `research/`,
   never the goal folder, plus the Notion mirror when configured —
   since research is usually reusable across goals), **Wayfinder mode** (below —
   if the goal
   turns out to be bigger than one execution session can hold), or direct
   user edits to `GOAL.md`. Each mode writes its own artifacts into the
   draft folder's corresponding subfolder (interview transcripts always go
   to `grilling/`, regardless of which skill produced them — `grill-me`,
   domain-modeling, or a wayfinder breadth-first pass all land here since
   they're all the same underlying interview mechanic).
3. **Promotion.** User explicitly triggers this (not a heuristic) — but the
   agent MAY proactively suggest promotion readiness (e.g. no new open
   questions surfaced in recent interview turns, all fog resolved) and offer
   to draft the issue; the promotion action itself only ever fires on
   explicit user confirmation. Draft an issue on the active tracker whose body mirrors
   `GOAL.md` (format: `references/templates.md`), with subsections linking
   out to `references/` files as **git
   permalinks with the commit hash baked in** (plus plain URLs where
   relevant), rendered as inline Markdown links. Push the goal branch
   before drafting the issue so those permalinks resolve.

   **Pre-flight — rebase onto the base first.** The draft branched from
   its base (main — or, for a stacked goal, its `stacked_on` parent; see
   Stacked goals) at draft time; by promotion the base has usually moved
   on. Rebase the draft onto its latest base **before** promoting
   (`rebaseGoalOntoBase`, which resolves the base from the draft's own
   `stacked_on` frontmatter — main when absent; make sure local main is
   current first): promotion is the last moment history may change,
   because the issue's permalinks pin commit hashes. On conflicts the
   rebase is left in progress in the draft's worktree — the agent
   resolves them there (`git rebase --continue`), then re-runs the
   helper, which force-pushes with lease. `promoteGoal` enforces this
   with a hard behind-base guard: behind-main for ordinary drafts,
   behind-parent for stacked ones — a stacked draft is deliberately
   behind main until its parent merges, and promotion must not demand
   otherwise.

   Then promote (all from inside the draft's worktree — `promoteGoal`
   handles the order): move the draft folder to `goals/ABC-NNN-{slug}/`
   (using the real issue key) via `git mv`, rename the branch to match,
   commit and push, and **move the worktree to `.worktrees/ABC-NNN-{slug}/`**
   (`git worktree move`, preserving the path-mirror invariant — the
   returned `worktreePath` is the folder's new home; the old path is
   stale). Frontmatter
   gets `status: promoted`, `promoted`, `issue_url`. Which tracker (and
   destination) a goal promotes into comes from the layered `.evie-agent`
   settings' `tools.tracker.*` block (EVA-26): the ACTIVE tracker is the
   one defined sub-block — `tools.tracker.linear` (team/project) or
   `tools.tracker.github` (repo/keyPrefix; issue keys become
   `<prefix>-<number>`, default `gh`) — committed per project;
   `evie-agent setup` scaffolds it; the legacy `tools.linear` and
   pre-EVA-19 top-level `linear:` keys error loudly at load. Skill text
   never hardcodes a team, because every project promotes somewhere
   different.
   If the block is unset, ask the user where goals promote and offer to
   record the answer in `.evie-agent/settings.yaml`. A team may keep a
   separate sandbox project for throwaway/dogfood goals used to exercise
   this workflow itself, never for real feature work. A stacked draft's
   promotion additionally records the tracker blocked-by relation to its
   parent's issue — see Stacked goals.

4. **Review-on-the-issue.** Once promoted, the primary review surface shifts
   to Linear: comments, direct edits, or messages to the agent — same
   three-channel feedback loop as drafting, but now user-driven rather than
   agent-driven. Advantage over local-filesystem iteration: a URL reachable
   from anywhere, shareable with a colleague, a durable team-visible record.
5. **Execution handoff.** User says the goal has solid footing. The
   handoff **adopts the goal's existing worktree** (created at draft
   time, moved at promotion) when it's at the expected path on the goal
   branch with a clean tracked state — one worktree per goal across its
   whole life. Dirty fails loud (commit or stash first); a fresh worktree
   is created only when absent. Launch a Claude Code session against it
   via `@evie-agent/herdr` + `@evie-agent/claude-code`
   (`AgentSession.start()` + `.sendGoal({kind: "promptFile", path:
".../GOAL.md"})`) — packaged as `@evie-agent/goals`'
   `startGoalExecution`, which also handles the worktree, the
   `started` transition, the **environment build** (the project's
   `.evie-agent/buildEnvironment.ts` hook's `apply()` runs after
   worktree adoption and its env vars are injected into the executor),
   and the **unisolated-launch check** (a project whose hook does not
   assert worktree isolation refuses to launch while another goal is
   executing — see Concurrent goals; `overrideUnisolatedLaunch: true`
   is the explicit accept-the-risk lever). `GOAL.md` must be
   self-sufficient: it should let the
   executing session navigate everything else it needs, in both the project
   and the goal folder, without additional hand-holding. Frontmatter gets
   `status: started`, `started`.
6. **Plan + execute.** The executing Claude Code session (now "the agent" in
   the sense of "the one doing the work" — see Roles above) builds its own
   plan and executes it, writing detailed narrative output to
   `results/RESULT.md` (format: `references/templates.md`).
7. **Green-gate review.** Green gates are **authored in `GOAL.md` during
   drafting**: whoever writes the goal defines what "done" must prove,
   dependent on the goal's objectives. A blind, multi-tool code review is
   the _default_ gate for coding goals; non-code goals define their own.
   For the code-review gate, the **executing session itself** spawns the
   reviewers — packaged as `@evie-agent/goals`' `runReviewWave` — as
   labeled tabs in its own herdr workspace (never a new workspace, never
   pane splits). Four tools are live: **Claude Code and Codex**
   (interactive TUIs) plus **SonarQube and CodeRabbit** (headless, wired
   in EVA-3). Reviews run **concurrently and blind** — sequential
   reviewing would let the second reviewer anchor on the first's
   findings, and reviewers see the change and the goal spec, never
   `RESULT.md` or another reviewer's findings. A reviewer that crashes
   or stalls is **reported as a failure of that wave**, never silently
   absorbed. Which tools run comes from the layered settings under
   **enabled-only semantics** (EVA-11): a tool whose settings block is
   DEFINED is part of waves — defining it declares the machine has
   it — and a defined tool that turns out unavailable **fails the wave
   up front**; `enabled: false` is the explicit off-switch (a recorded,
   visible `skipped` outcome); an undefined tool is simply not part of
   the wave (INDEX.md records absent tools with terse
   `not-configured` rows, and the wave enforces that a driver covers
   every defined tool — the gate cannot silently shrink). Each wave
   writes `reviews/wave-NNN/` (3-digit zero-padded per-goal index;
   legacy datestamped `review-<ts>/` folders in locked goals stay
   readable) with per-tool
   subfolders and an `INDEX.md` (format: `references/templates.md`)
   whose "Merged findings" section the executing session fills by its
   own judgment — no mechanical union-is-blocking or vote-threshold
   rule; multi-tool blind review exists to surface more candidate
   issues than one reviewer alone would, not to reach algorithmic
   consensus. Multiple waves are supported (indexed folders,
   per-reviewer provenance in each INDEX.md).

   Read `references/review-waves.md` **before running a wave**: the
   operational mechanics (tab lifecycle and sweep rules, completion
   detection per tool kind, timeout/backstop and blocked-reviewer
   handling), the layered `.evie-agent/settings.*` configuration
   surface, the stale-reviewer gotcha, and the verified driver example
   all live there.

8. **Completion.** Once the goal's green gates pass, the executing session
   writes/finalizes `results/RESULT.md` and sets `status: completed` and
   the `completed` timestamp in `GOAL.md`'s frontmatter itself. This is
   the terminal, locking event. What happens to the branch/PR afterward —
   merge, further human review, abandonment — is the **user's decision**,
   outside the goal's lifecycle; anything the user surfaces
   post-completion becomes a new goal loop referencing this one. When
   the branch IS merged (real merge commit with a descriptive
   `merge: …` subject, per the directory-conventions section), the
   merge has FOUR companion steps, in order: tearing down the goal's
   built environment (`teardownGoalEnvironment` — runs the project
   hook's `teardown()`; BEFORE the worktree removal, since the hook and
   its overlays live in the worktree; a no-op on projects without a
   hook), removing the goal's worktree (`removeMergedGoalWorktree`,
   guarded by the remove-on-merge rule under Worktree layout above),
   deleting the branch's ephemeral SonarQube project
   (`deleteSonarBranchProject` — `absent` is fine, the goal's waves
   may never have run sonar; all keyed by the merged branch), and
   refreshing the authoritative sonar board with a fresh scan from the
   main checkout (waves never scan the base project, so nothing else
   updates it). Merges themselves are SERIALIZED by the
   orchestrator — see Concurrent goals — and a stack of goals lands
   parent-first, each child then retargeting its PR to main with no
   rebase — see Stacked goals.

## Concurrent goals (parallel execution)

Multiple goals may execute at once on one machine (EVA-11). The
mechanism makes it structurally safe; the JUDGMENT stays with the
orchestrator — the coordinating agent owns sequencing and refuses risky
overlap, the tooling gives it the information and the levers.

What makes concurrency safe (all in place, nothing to do per goal):

- **Filesystem**: every goal executes in its own worktree (EVA-8).
- **Shared infra**: the project's **environment hook** —
  `.evie-agent/buildEnvironment.ts` (EVA-24, superseding EVA-11's
  `resources:` declare-and-serialize ledger). One default-exported
  function makes a worktree genuinely independent:
  `buildEnvironment(ctx) => { isolated, apply?, teardown? }`. The call
  is CHEAP (no side effects); `apply()` runs at launch, does the real
  container/DB/port work labeled with `ctx.key` (reap-then-create, so
  crashes self-heal), and returns the env injected into the executor;
  `teardown()` reaps at merge cleanup. `ctx` provides `readSource`,
  `writeOverlay` (gitignored generated files — the source tree is never
  mutated), `reservePorts` (held), `portFor` (deterministic), and
  env/TOML helpers. **Inverted signal**: `isolated: true` is the
  project ASSERTING worktrees are independent — that assertion, not a
  ledger, is what unlocks parallelism. The bootstrap stub (written by
  `evie-agent setup`) returns `{ isolated: false }` = no assertion.
  All-or-nothing: assert only when the worktree is FULLY independent.
- **Agent names**: executor and reviewer names carry the goal key
  (`<KEY>-cc`, `<KEY>-cc-review`, … — EVA-9), so herdr's server-global
  namespace cannot collide and a wave's tab sweep only ever matches its
  own goal's labels. Each executor keeps ONE workspace (its own tabs),
  as today.
- **SonarQube**: every wave scans into the ephemeral per-branch
  project `<baseKey>-<branch>` (auto-created on first scan), so
  concurrent scans cannot clobber each other and each wave's verdict
  is provably against its own tree. The authoritative base project is
  only ever scanned from main, post-merge, outside the wave path.
- **Waves**: fully concurrent across goals — reviewers, watchers, and
  completion detection are all goal-scoped. The wayfinder
  one-loop-at-a-time rule is unchanged and PER MAP, not global: one
  map's work stays serial, but goals from different maps (or mapless
  goals) may overlap.

What needs judgment (the orchestrator's contract):

- **Launch**: when the project's environment hook does NOT assert
  isolation (`NOT_ISOLATED` — the no-op stub, or no hook at all),
  `startGoalExecution` refuses to launch while ANY other goal is
  executing (discovery: worktrees at the mirror path with a started
  GOAL.md, enriched by herdr session liveness — no registry file).
  Overriding (`overrideUnisolatedLaunch: true`) is the
  user's/orchestrator's explicit call. A project asserting
  `isolated: true` overlaps freely — the hook's isolation is what makes
  that safe. Launches, like merges, are **orchestrator-serialized** —
  one `startGoalExecution` at a time: the check closes mistakes, not
  races (two launches passing the check simultaneously would each miss
  the other, since neither is `started` yet). Discovery is
  convention-based: a goal started at a custom `worktreePath` (off the
  mirror path) is invisible to it — an unisolated project refuses a
  custom path outright.
- **Merges are serialized**: locked goals merge to main ONE AT A TIME,
  orchestrator-sequenced — never two merges racing. If a merge required
  conflict resolution, that resolution happened AFTER the goal's review
  wave — so before pushing, re-verify on the merge result: workspace
  tests + a fresh scan. A conflict-free merge (still a REAL merge
  commit — fast-forwards are never used, per the directory-conventions
  section) needs no re-verification.
- **Soft contention** (model throughput, CodeRabbit tier limits, user
  attention) is self-regulating and deliberately untooled — just be
  aware that N concurrent waves multiply reviewer load.

## Stacked goals (building on an unmerged parent)

When a goal depends on another goal's still-unmerged branch — in team
repos a PR can wait on human review for days — the dependent work does
NOT stall: draft it **stacked on the parent branch** instead of main
(EVA-18). The never-squash convention is what makes this cheap: because
goal branches land as **true merge commits**, a child branched from its
parent needs **zero restacking when the parent merges** — the parent's
commit hashes stay reachable from main, the child's diff-to-main
collapses to its own commits, and Linear permalinks survive untouched.
(Deep-stacking tools like Graphite earn their keep in squash-merge
workflows, where every parent merge rewrites history under the child;
we deleted that problem by convention — an explicit non-goal, revisit
only if stacks become the norm rather than occasional and shallow.)

The mechanics are level-invariant — a grandchild stacks on a child the
same way; there is no artificial depth cap. Absent `stacked_on`, every
path below behaves byte-identically to the main-based flow.

- **Draft**: pass `stackedOn: "<parent-branch>"` to `startDraft` — the
  draft is born FROM the parent branch (the primary checkout still
  never leaves main) and `stacked_on: <parent>` is recorded in the
  frontmatter. Everything stacking-aware reads that one key. The parent
  must be a **promoted** goal branch (`ABC-NNN-slug`) — `startDraft`
  refuses anything else, because promoting a parent RENAMES its draft
  branch (and deletes the old remote name), which would orphan every
  child's `stacked_on`; promote the parent first.
- **The environment hook rides the branch**: a stacked child's launch
  reads `.evie-agent/buildEnvironment.ts` from its OWN worktree, which
  includes the parent's unmerged changes — so a hook the parent
  introduced or modified is already in force for the child. No
  per-goal declaration exists to carry forward (EVA-24 removed the
  `resources:` ledger).
- **Promotion**: the pre-flight rebase and the hard guard both use the
  parent as base automatically (lifecycle step 3). `promoteGoal` hands
  the driver `stackedOn` (parent branch + issue key) in the
  `createIssue` context — record the **Linear blocked-by relation** to
  the parent's issue there, so the stack is visible on the board.
- **Review waves diff against the parent**: a stacked goal's wave
  must judge only its OWN commits — `git diff <parent>...HEAD` — never
  re-review the parent's diff. Driver-level, two knobs: the
  `changeSpec` names the parent as BASE, and `CodeRabbitReviewer` gets
  `base: <parent>`. Derive BASE from the goal's own frontmatter
  (`stacked_on` ?? `main`) so a copied driver stays correct — EVA-18's
  committed driver is the reference. SonarQube needs nothing: its
  per-branch ephemeral projects already scan the child's whole tree.
- **Merge choreography** (the orchestrator's contract, extending the
  serialized-merges rule): the stack lands **parent-first**, walking
  the `stacked_on` chain at any depth. After the parent's true merge,
  the child PR simply **retargets to main** (`gh pr edit --base main`)
  — its diff is already correct, **no rebase**. The one case that DOES
  rebase: the parent's branch is revised BEFORE its merge (review
  feedback, force-with-lease push) — the child then rebases onto the
  updated parent (`rebaseGoalOntoBase`, same conflict-resolution flow
  as the promotion pre-flight). Two caveats on that catch-up rebase:
  the target is the LOCAL parent ref, so freshen it first (`git pull
--ff-only` in the parent's own worktree — the parent branch is
  checked out there, so a `fetch <parent>:<parent>` refspec is
  refused); and once the child has PROMOTED, rebasing rewrites commits
  its issue already pinned — the old hashes survive only as
  forge-served dangling SHAs, not reachable-from-main history. Prefer
  landing a parent unrevised once children have promoted; revising it
  anyway is an accept-the-permalink-cost call, made knowingly.
- **Cleanup refuses stack-aware**: `removeMergedGoalWorktree`'s
  not-ancestor-of-main guard is unchanged, but for a stacked goal the
  refusal names the unmerged parent and says the stack must land first
  — "merge this branch" alone would point at the wrong next action.

## Wayfinder mode (oversized ideas)

If, during drafting, breadth-first grilling reveals real fog — open
questions that keep spawning further open questions, not resolvable in
one execution session (a judgment call made during `grill-me`, not a
mechanical threshold) — don't force the idea into one oversized goal:
chart it as a **wayfinder map** and resolve tickets one at a time until
the way to the destination is clear. The map lives as `MAP.md` in the
active goal's own `wayfinder/` subfolder and is recrafted forward
goal-by-goal as each goal locks. Read `references/wayfinder.md` (in
full) before charting, working through, or recrafting any map — it
holds the when-to-chart test, the canonical `MAP.md` body, ticket types,
the fog-of-war discipline, the one-execution-loop-at-a-time hard rule,
and both invocation sub-modes.

## Invoking `@evie-agent/goals`

The lifecycle verbs are library functions — the package registers no bin
of its own (one-bin rule: the only bin any `@evie-agent/*` package
registers is `evie-agent`, owned by `@evie-agent/cli`); the door
verbs ride the unified CLI as `evie-agent goals draft | list | completed
| context | rebase | promote | execute | review` (the lifecycle four
landed in EVA-22 — in a repo where setup linked only `@evie-agent/cli`,
the CLI verb is the CANONICAL invocation for those steps; the `bun`
one-liners below remain the escape hatch and the orchestrator's
programmatic surface). Anything else is
invoked from a short `bun` script or one-liner at the repo root, where
bun resolves the package (workspace or linked). Verified surface — the
package's public exports (`startDraft`, `rebaseGoalOntoBase`,
`promoteGoal`, `startGoalExecution`, `runReviewWave`,
`removeMergedGoalWorktree`, `deleteSonarBranchProject`,
`discoverRunningGoals`, the door functions `detectGoalContext` /
`readGoalsSurface` / `classifyIntake` / `captureIntake` and the list
views, the pure primitives `createDraft` / `scaffoldGoalFolder`, and
the frontmatter transitions `transitionGoalFile` / `startFrontmatter` /
`completeFrontmatter`).

- **Draft** (step 1): from the primary checkout, on main:

  ```bash
  bun -e 'import { startDraft } from "@evie-agent/goals";
  const d = await startDraft({ repoRoot: process.cwd(), slug: "my-idea",
    timestamp: new Date(), title: "My Idea",
    frontmatter: { author: "evie", repo: "my-repo" } });
  console.log(d.worktreePath, d.branch);'
  ```

  Branch, worktree at `.worktrees/drafts/<ts>-<slug>/`, scaffold,
  commit, and push in one step — the primary checkout stays on main.
  Work on the draft inside `d.worktreePath` from here. For a draft born
  from a `/goals draft` intake, use `captureIntake` (or `evie-agent
goals draft`) instead — same startDraft underneath, plus the verbatim
  `references/intake.md` capture (see The `/goals` door above). To
  stack the draft on an unmerged parent goal branch, add
  `stackedOn: "<parent-branch>"` (see Stacked goals).

- **Promotion pre-flight** (step 3): with local main freshened first —
  `git pull --ff-only` **on the primary checkout** (which is on main;
  `git fetch origin main:main` does NOT work here — git refuses to
  update a branch that a checkout has checked out),

  ```bash
  # from inside the draft worktree (or --worktree <path>):
  evie-agent goals rebase
  # equivalent library call:
  bun -e 'import { rebaseGoalOntoBase } from "@evie-agent/goals";
  console.log(await rebaseGoalOntoBase({
    worktreePath: ".worktrees/drafts/<ts>-<slug>" }));'
  ```

  The rebase target resolves from the draft's own `stacked_on`
  frontmatter (main when absent) — nothing extra to pass for a stacked
  draft. On conflicts this leaves the rebase in progress in the
  worktree — resolve there, `git rebase --continue`, re-run to
  force-push (with lease). Then promote — `evie-agent goals promote`,
  run from inside the draft worktree (EVA-22): it re-runs the rebase
  pre-flight itself, creates the issue on the active tracker from the
  layered `tools.tracker.*` block (EVA-26: Linear team/project/apiKey,
  or GitHub via `gh`; the body mirrors GOAL.md
  with permalinks pinned to the real pushed head, each linked path
  verified with `git cat-file -e` — never extend a short hash), then
  drives `promoteGoal`. `--issue KEY` (optionally `--issue-url URL`)
  escapes to an issue created elsewhere (the orchestrator case); with
  no resolvable API key and no `--issue`, it fails loudly — a goal is
  never promoted without an issue. Programmatic callers use
  `promoteGoal` (with `repoRoot` = the draft worktree) directly; either
  way branch + folder + worktree rename together — use the returned
  `worktreePath` afterward, the drafts/ path is stale.

- **Execution handoff** (step 5): from the orchestrator, on the primary
  checkout (which must NOT have the goal branch checked out) —
  `evie-agent goals execute ABC-NNN` (EVA-22; accepts the bare issue key
  or the full folder name, `--mode`/`--model`/
  `--override-resource-contention` pass through) resolves the stated
  herdr session itself. Programmatic equivalent:

  ```ts
  // save as a script (or inline via bun -e) and run at the repo root
  import { HerdrClient } from "@evie-agent/herdr";
  import {
    herdrBindingFor,
    loadSettings,
    startGoalExecution,
  } from "@evie-agent/goals";
  const repoRoot = process.cwd();
  // Session binding must be STATED (EVA-20): tools.herdr.session when
  // set, else a slug of the repo name — a bare `new HerdrClient()`
  // throws rather than silently binding the machine's default socket.
  const { settings } = await loadSettings(repoRoot);
  await startGoalExecution({
    repoRoot,
    goalRelPath: "goals/ABC-NNN-the-slug",
    herdr: new HerdrClient(herdrBindingFor(settings, repoRoot)),
    timestamp: new Date(),
  }); // adopts .worktrees/<branch> (creates it only if absent),
  //    marks started, launches the executor
  ```

- **Review wave** (step 7): `evie-agent goals review` from inside the
  goal's worktree (EVA-22) — the goal comes from the branch (or pass
  `ABC-NNN`), the diff base from its `stacked_on` frontmatter (or
  `--base`), reviewers from the settings' defined tool blocks; the
  stated-session binding, bound-session workspace resolution, and
  per-tool stall thresholds are the EVA-20/21 reference-driver shape,
  productized. This is what makes waves runnable in a foreign repo
  where setup linked only `@evie-agent/cli` (the VER-215 gap — driver
  scripts import sibling packages by name, which only resolve from
  inside the workspace). Credential sourcing still applies
  (`references/review-waves.md`). Write a goal-specific driver script
  (copy-adapt EVA-21's `goals/*/results/run-review-wave.ts` reference)
  only when the gate needs assertions beyond the wave itself —
  pre-EVA-21 `run-review-round.ts` drivers target the removed
  `runReviewRound` API and fail loudly.

## Non-goals (explicitly deferred, this pass)

- Notion as a review surface (only Linear in this pass; EVA-19 wired
  Notion only as a research-artifact DESTINATION via
  `storage.research.outputs`).
- Hindsight write-through on goal/research completion (retrieval landed
  in EVA-19 — `evie-agent hindsight recall`, the grounding ladder's
  episodic rung; the WRITE path stays deferred).
- Codex/OpenCode/Pi as _executors_ (only Claude Code executes goals in this
  pass; Codex participates only as a **reviewer**).
- Spawning reviewers as managed tmux sessions when the executor runs
  outside herdr (only the herdr path is wired in this pass).
- Tracker-canonical wayfinder maps (map/tickets living natively in Linear,
  as upstream wayfinder does) — a per-project config axis later; local
  file-tree maps only in this pass.
- Tailscale port exposure / SQLite-vs-Postgres storage flexibility (tracked
  separately; not required for this pass while Postgres is already
  available).
- Composable Basic Memory + Hindsight memory layering (EVA-19 made the
  config shape ready — `tools.memory.basicMemory` is a recognized
  settings kind — but the search-client integration is its own
  follow-up goal).
- The "subprocess authenticates back to the OpenClaw gateway to notify/wake a
  channel" primitive — for this pass, notify/wake for a goal running under
  direct OpenClaw orchestration can rely on OpenClaw's existing in-process
  cron/message-wake mechanisms; a detached-subprocess-calls-back-in variant
  is out of scope.

## Follow-ups (tracked, not in this skill's current scope)

- **`loopFolder` → `goalFolder` rename** in `@evie-agent/coding-agent`
  (breaking API change to a reviewed, tested package — file, types,
  function names, and possibly the `loop-YYYYMMDD-HHmmSS-slug` naming
  pattern itself). Needs its own goal.

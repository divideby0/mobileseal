# Review waves: mechanics, configuration, driver

Operational detail behind lifecycle step 7's summary. Read this in full
before running, monitoring, or debugging a blind review wave, and when
touching the `.evie-agent/settings.*` review configuration. The INDEX.md
format the wave generates is in `references/templates.md`.

## How a wave runs

The **executing session itself** spawns the reviewers, via herdr — the
only wired path; an executor outside a herdr pane must pass a workspace
explicitly or the wave fails fast (a tmux fallback stays deferred, see
SKILL.md Non-goals). Each reviewer runs as a **labeled tab in the
executing session's own herdr workspace** (`ABC-9-cc-review`,
`ABC-9-cd-review`, … — the per-goal naming contract below) — never a
new workspace, never pane splits. The wave resolves that workspace
from the caller (explicit option or `HERDR_WORKSPACE_ID`) and throws
rather than silently creating one.

## The per-goal naming contract

herdr agent names are **server-global**, so every goal-scoped agent name
is prefixed with the goal's Linear issue key (EVA-9):

- Reviewers: `<KEY>-cc-review`, `<KEY>-cd-review`, `<KEY>-sq-review`,
  `<KEY>-cr-review` (cc=claude-code, cd=codex, sq=sonarqube,
  cr=coderabbit) — `reviewerTabLabel(goalKey, tool)`.
- The executor session itself: `<KEY>-cc` — `executorAgentName(goalKey)`,
  applied by `startGoalExecution`.
- Reviewer tab labels equal agent names (the tabs are created with the
  label). The executor's own workspace-initial tab is different: it is
  best-effort renamed to the agent command (`claude`/`codex`) after a
  successful launch — cosmetic, not a guarantee to build logic on.

With unique per-goal names, `agent_name_taken` across goals is
structurally impossible, and concurrent goals run waves in parallel
(the full concurrency contract — sonar isolation, resource
declarations, merge serialization — is in SKILL.md's Concurrent goals
section). The wave derives the key from its `goalRoot` basename and
therefore only runs for promoted goal folders (`ABC-NNN-slug`); a
driver that names its interactive reviewer sessions anything other than
`reviewerTabLabel(goalKey, tool)` breaks the sweep — copy a prior
goal's driver rather than improvising.

Reviews run **concurrently and blind** (sequential reviewing would let
the second reviewer anchor on the first's findings), but tab setup
itself is serial — herdr spawns unfocused tabs' terminals lazily, and
interleaving two setups can lose typed input. Goal delivery is verified
before any resend.

**Interactive reviewers review their own worktrees (EVA-16, from
VER-213)**: at setup each cc/codex reviewer gets an ephemeral
`git worktree` of the checkout's HEAD — the SAME commit, so blindness
is preserved — with `bun install` run when the tree has a lockfile
(~0.9s per reviewer, measured), removed unconditionally at wave end.
One reviewer's build can no longer tear state under another's analysis
and feed a FALSE "build broken" finding into blind reconciliation.
Headless tools stay on the shared tree (sonar's workdir is off-repo;
coderabbit reads the diff). Drivers can opt out with
`interactiveIsolation: "shared"`. Belt-and-braces, every reviewer
prompt also carries a working-tree-discipline clause
(`buildReviewerPrompt`): no watch modes or servers, prefer typecheck
over full builds, re-run surprising build/artifact state once before
reporting it as a finding.

**Launch-phase spawn retry (EVA-16)**: the codex spawn race is
recurring (EVA-10, EVA-15 round 1) — `agent_not_found` when the tab
vanishes between `agent start` and the first wait. An interactive
launch that dies with a `*_not_found` error gets ONE automatic retry
with a fresh tab; each attempt's evidence (error + the pane's last
screen, captured before the failed tab closes) lands in the tool dir
as `launch-failure-<n>.txt`. Launch-infrastructure retry is not
absorption — a reviewer that fails after a clean launch still fails
the wave.

**Completion detection**, per tool kind:

- Interactive TUIs (Claude Code, Codex): agent-state polling with
  debounced blocked/stalled classification plus a FINDINGS.md
  completion marker — some TUIs settle to `idle` without ever reporting
  `done`; herdr's blocking `wait agent-status` remains available via
  `AgentSession.waitForState`.
- Headless tools (SonarQube, CodeRabbit): the `.done`/`.failed` file
  channel. They stream full output live into their tab (tee semantics —
  the tab is the observability surface).

**SonarQube scans are per-branch isolated (EVA-11)**: the reviewer
derives the checkout's branch at run time and scans into the ephemeral
project `<projectKey>-<branch>` (sanitized, hash-disambiguated when
sanitizing was lossy; auto-created on first scan), fetching its verdict
from that same project — the configured `projectKey` is only the BASE.
A sonar scan replaces the target project's snapshot, so this is what
makes concurrent waves' verdicts independent. The reviewer also WAITS
for the server's asynchronous compute task before reading issues
(scanner exit only means the report uploaded; fetching earlier returns
the PREVIOUS analysis — observed live in EVA-11's first gate round, and
the reason FINDINGS.md pins the compute-task id). Two consequences for
reconciliation: ephemeral projects start FRESH and do not inherit the
base board's issue resolutions, so expect resolved/Accepted items to
resurface — judge sonar findings against the goal's own diff, never
the project-wide OPEN count. The ephemeral project is deleted at merge
cleanup (`deleteSonarBranchProject`, alongside
`removeMergedGoalWorktree`), and the merge's third companion step
refreshes the authoritative board with a fresh scan from the main
checkout — the base project is never scanned from a goal branch.

The **executing** session is the one that must know when reviews are
done — it's gating its own completion on this — not just the
orchestrator.

**Watching for a reviewer tab from OUTSIDE the driver** (an
orchestrator or a shell watcher): use `@evie-agent/herdr`'s
`waitForAgent(client, "<KEY>-cd-review", { ceiling })` — never a
hand-rolled `until herdr agent list | grep …; do sleep …; done` loop.
Unbounded watchers spun for 29 minutes on a wedged spawn (EVA-20,
trellis TRLS-8: `agent list` answers in ~5ms, the agent was simply
absent). On the ceiling the helper returns an `absent` sentinel; treat
it as that reviewer's recorded failure and proceed, per the
never-absorbed rule.

## Failure and skip semantics (enabled-only, EVA-11)

A reviewer that crashes or stalls is **reported as a failure of that
wave**, never silently absorbed. Each reviewer gets a generous
backstop timeout (default 120m), but catch failures far earlier via
agent-state awareness — in particular a reviewer blocked waiting for
user input, a real failure mode for interactive tools that headless
ones don't share. Review prompts must instruct interactive reviewers to
never block on questions (`buildReviewerPrompt` does).

**Per-reviewer stall detection (EVA-16, from EVA-11's round-2 wedge —
CodeRabbit sat 40+ minutes with only the backstop watching)**: every
reviewer's screen/pane output is re-read each poll; output frozen past
the threshold (default 10 minutes, `review.stallTimeoutMinutes`)
records a loud per-tool `stalled` outcome while the wave continues
with the remaining tools. Thresholds are per-tool aware: settings
`tools.review.<tool>.stallTimeoutMinutes` beats the reviewer
implementation's own declared threshold beats the wave level.
CodeRabbitReviewer declares a 60-minute threshold — its piped
`--plain` output is legitimately silent during remote analysis, and
manufacturing synthetic pane progress would defeat the detector
(EVA-16 round-2 blocker), so for that tool the backstop is the wedge
guard. A reviewer that ends `stalled`/`timeout`/`blocked` is STOPPED
at wave end regardless of `tabCleanup` — its process is still live,
and a late completion write would contradict the recorded outcome in
the committed wave artifacts (final screen is captured first).

**The between-waves sweep tolerates vanished tabs (EVA-16, the EVA-12
TOCTOU)**: a tab that closes between `tabList` and `tabClose` is the
benign already-swept state; a LIVE tab that refuses to close fails
only that tool's reviewer (the wedged tab still holds its
server-global agent name) and the wave continues.

**Generated `run.sh` is self-locating (EVA-16)**: committed wave
artifacts embed no machine paths — tool dir from `BASH_SOURCE`,
checkout from `git rev-parse --show-toplevel` at the invocation cwd.
Only the ephemeral secrets path is absolute, commented NON-REPLAYABLE;
a committed run.sh is a record, not a replayable script.

Which tools are in a wave is decided by DEFINITION, not a `required`
flag (that key is gone — its presence in any settings layer errors at
load, naming the file):

- A tool whose settings block is **defined** in some layer is part of
  waves and enabled — defining the block declares the machine has it.
- A defined tool that turns out **unavailable** — probe failed, binary
  missing, or ANY key knocked out by an unresolved `${ENV_VAR}` (the
  driver passes `loadSettings`' `unavailableTools` into the wave's
  `unavailable` option) — fails the wave **up front** — you declared
  you have it, and a knocked-out key would silently run a different
  model/scope/base than declared.
- `enabled: false` on a defined block is the explicit temporary
  off-switch: a recorded, visible **`skipped`** outcome; the tool is
  never probed and its tab never spawns. This is the ONLY skip path.
- An **undefined** tool is simply not part of the wave. Drivers pass
  `definedTools` (their settings view) and the wave ENFORCES coverage:
  every defined tool must have a reviewer (pass it even when
  `enabled: false` so the skip is recorded) — a driver cannot silently
  shrink the gate. INDEX.md then records absent tools as
  `not-configured` (provably no settings block), or `not-in-wave`
  when the wave wasn't given `definedTools` (e.g. a deliberately
  scoped diagnostic wave like EVA-11's isolation demo).

The committed project layer defines the tools every contributor
running a gate wave is guaranteed to have; machines with more define
the rest in their personal `.evie-agent/settings.local.yaml`.

## Tab lifecycle between waves

A completed wave's tabs stay open for reconciliation (scrollback
intact); the NEXT wave's setup sweeps them — interactive tabs closed
and recreated (never reused: blindness), headless tabs reusable in
place. `review.tabCleanup: keep | close | prompt` configures what
happens after a wave. Note that reviewer WORKTREES are removed at
wave end regardless of `tabCleanup` (EVA-16): a kept interactive tab
survives with its cwd deleted, so it is a scrollback/interrogation
transcript, not a live workspace — reconciliation evidence comes from
the wave dir (FINDINGS.md, screen.txt), never the reviewer's tree.
The codex reviewer additionally needs the goal's `reviews/` dir as a
sandbox `writableRoots` entry (see the driver): its `workspace-write`
sandbox is scoped to the ephemeral worktree, and without the extra
root it cannot write FINDINGS.md back into the executor tree (round-1
gate failure, EVA-16).

The sweep matches only THIS goal's labels: another goal's kept reviewer
tabs carry another key and are never touched — closing them could kill
a LIVE parallel wave. They are harmless clutter until that goal's
merge-time worktree removal. (History: before per-goal names — EVA-9 —
reviewer names were the shared `claude-code-review`/`codex-review`, and
a prior goal's kept tabs would `agent_name_taken`-kill the next round;
this bit EVA-6's first round and needed a manual preflight. Per-goal
keys make that collision structurally impossible.)

## Blindness contract

Reviewers are blind to each other **and** to the executing agent's own
narrative — they see the change and the goal spec, not `RESULT.md` or
another reviewer's findings. Findings merge afterward into the wave's
`INDEX.md`, which the executing session reconciles by its own judgment
(no union-is-blocking, no vote threshold — the point of multi-tool
blind review is surfacing more candidate issues than one reviewer
alone would catch, not algorithmic consensus). Multiple waves are
supported — indexed `reviews/wave-NNN/` folders (see Folder naming
below), per-reviewer
provenance recorded in each INDEX.md.

## Configurable mechanisms (settings surface)

Per-tool review config lives at **`tools.review.<tool>`** (EVA-19
reshape — everything under `tools.*` is a capability with an engine
behind it; the pre-reshape `review.tools.*` errors loudly at load,
naming the file): definition = availability declaration, `enabled`,
credentials, model, effort/reasoning, extra args, tool-specific keys
like sonar `projectKey`. Wave DIRECTIVES stay in the `review:` block —
`review.tabCleanup`, `review.stallTimeoutMinutes` (per-reviewer stall
threshold, EVA-16; unset = 10 minutes) — and the ADHD axes
(`adhd.branchExecution: multiplexer` with `adhd.multiplexer: herdr` /
`adhd.layout: tabs | panes`, or `adhd.branchExecution:
local-subagents`) keep their own directive block. The same `tools.*`
namespace carries the grounding/research capabilities (`tools.memory.*`
recall sources, `tools.research.exa`, `tools.notion`,
`tools.tracker.{linear,github}`)
and `storage:`/`research:` directives — one layered settings surface,
mirroring Claude Code's own structure. **`tools.herdr`** (EVA-20)
carries the repo's herdr binding: `session` (which herdr session every
goals-machinery client binds; the literal `default` is the explicit
shared-socket opt-in) and `agentStartTimeoutMs` (spawn-RPC bound,
default 60s). When `session` is unset, `herdrBindingFor` derives a slug
of the repo name — a fresh repo gets its OWN isolated session; the
default socket is never inherited by omission:

1. built-in defaults
2. `~/.evie-agent/settings.{ts,js,json,yaml}` (user)
3. `{repo}/.evie-agent/settings.*` (project, committed)
4. `{repo}/.evie-agent/settings.local.*` (personal, gitignored —
   credentials live here)

`json`/`yaml` interpolate `${ENV_VAR}` in string values (an unresolved
var inside a tool block marks that tool unavailable rather than
crashing); `ts`/`js` default-export the object and read `process.env`
directly. Everything is zod-validated post-merge; nothing repo-specific
is baked into the skills or their backing packages — behavior must run
identically against any repo. Load order and schema:
`@evie-agent/goals`' `loadSettings`.

## The driver

`runReviewWave` (with `buildReviewerPrompt`, `CodexSession`,
`SonarReviewer`, `CodeRabbitReviewer`) is a library surface; each goal
runs it from a short `bun` driver committed in its own `results/`.
Copy-adapt the NEWEST prior committed driver in the project
(`goals/*/results/run-review-wave.ts`; pre-EVA-21 goals committed
theirs as `run-review-round.ts` against the old `runReviewRound`
API — historical artifacts, like all locked drivers. In the
evie-agent repo, EVA-21's is the current reference: indexed wave
folders plus everything EVA-20 hardened — stated-session client via
`herdrBindingFor(settings, repoRoot)`, workspace resolved against the
BOUND session, worktree-aware three-arg `buildPrompt`, codex
`writableRoots`, per-tool stall thresholds, post-wave tab-layout
assertion; older drivers' two-arg builders fail reviewer setup loudly
under the default isolation, and pre-EVA-20 drivers construct a bare
`new HerdrClient()`, which now THROWS the teaching error — that loud
failure is the fix working, not a bug in the old record): it loads
settings, derives the goal key for the per-goal reviewer
names, and builds a reviewer for every DEFINED tool with per-tool
provenance (enabled-only semantics — no `required` flags). Drivers
from goals before EVA-11 pass `required:` options that no longer exist
and settings layers that no longer parse; drivers before EVA-9
additionally fail loudly on the one-arg `reviewerTabLabel`. Locked
goals' committed drivers are historical artifacts — never re-run them.

A follow-up wave's diff necessarily contains the PREVIOUS wave's
committed records; reviewers must not re-litigate them. Interactive
reviewers are told so in the driver's `changeSpec`; CodeRabbit reads
the raw diff and ignores prompts, so the repo-root `.coderabbit.yaml`
excludes `goals/**/reviews/**` via `reviews.path_filters` (EVA-9).

Run it from the worktree root; review credentials are usually NOT in a
fresh worktree — source them from the main checkout first:

```bash
set -a; source "$(git rev-parse --path-format=absolute --git-common-dir)/../.envrc.local"; set +a
bun goals/<ISSUE-KEY>-<slug>/results/run-review-wave.ts
```

Each reviewer writes to its own
`reviews/wave-NNN/{claude-code,codex,sonarqube,coderabbit}/`
subfolder; the wave's `ok` is a process verdict only — the gate passes
when the reconciled INDEX.md says so.

## Folder naming (indexed waves, EVA-21)

Wave folders are **per-goal sequential**: `reviews/wave-001`,
`wave-002`, … (3-digit zero-pad, the adhd `session-NNN` precedent) — a
human reads "wave 1, wave 2, wave 3" instead of parsing timestamps.
The writer (`reviewWaveDirName` + `nextReviewWaveIndex`) computes the
next index as max existing `wave-NNN` + 1, starting at 001.

Waves were datestamped `review-YYYYMMDD-HHmmSS/` before EVA-21
("rounds"). Locked goals keep those folders — locked means immutable
history — so READERS must resolve both forms: `isReviewWaveDirName`
and `listReviewWaveDirs` accept legacy names, and reconciliation
across a goal's historical waves still works. Legacy folders never
feed the index; a goal with datestamped history starts its indexed
sequence fresh at `wave-001`.

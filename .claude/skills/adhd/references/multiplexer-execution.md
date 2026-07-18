# Multiplexer execution runbook (`branchExecution: multiplexer`)

Read this when — and only when — the resolved `adhd.branchExecution` mode
is `multiplexer`. It is the mandatory, script-driven mechanism for
spawning frame sessions; the frame-selection judgment stays with the
orchestrating model (SKILL.md, "Branch execution"). Evidence trail for
everything here: `research/adhd-spike-findings-index.md` at the repo root
— "the spike index" below.

## Use the scripts, not prose

The first real run of this strategy (prose-instructed, no scripts) produced
real, working panes — but with two silent defects that a live user caught
and a live user would not have caught from the transcript alone: (a) panes
came out unevenly sized (CC was never told the split math, so it improvised
sequential binary splits that don't divide space evenly for N>2), and (b)
CC defaulted to launching `claude -p "$(cat prompt)"` (headless/print mode,
runs once and exits) instead of an interactive session — silently defeating
the entire point of the pane strategy, since nothing stays open to watch.
See the spike index for the full account.

Both defects are now closed by moving the mechanical parts — pane math,
process launch mode, prompt delivery, result collection — out of prose and
into real scripts: the `@evie-agent/adhd` package (`packages/adhd` in the
evie-agent repo). The package registers NO bins of its own — its commands are
subcommands of the single unified `evie-agent` bin owned by
`@evie-agent/cli` (EVA-13; bin collisions in the flat node_modules/.bin
namespace are silent, verified EVA-4): `evie-agent adhd
write-frame-prompts`, `evie-agent adhd spawn-frames`, and `evie-agent
adhd collect-frames`.

**Script resolution.** The exact command lines below spell the full
durable path `bun node_modules/@evie-agent/cli/src/evie-agent.ts` — an
alias or exported variable would NOT survive between an agent's separate
shell invocations, and this runbook's whole point is commands that work
verbatim in a fresh shell. Inside the evie-agent repo that path exists
after `bun install`, with zero ambiguity (never bare-`bunx` a name that
might not be installed — bunx falls back to the public registry). In any
other project, run this preflight once before step 1:

```bash
[ -x node_modules/.bin/evie-agent ] || bun link @evie-agent/cli
```

and substitute `./node_modules/.bin/evie-agent` for the
`bun node_modules/@evie-agent/cli/src/evie-agent.ts` prefix in each
command below.

`bun link` installs a symlink to the live package source, so the consumer
always runs current code. If it fails with a package-not-found error, the
one-time machine setup is missing: run setup by path from the target
project (`bun <evie-agent-checkout>/packages/cli/src/evie-agent.ts setup`
— the by-path form is the one that works while the bin doesn't exist
yet), or from an evie-agent checkout
`cd packages/cli && bun link` registers the package; re-run if that
checkout ever moves — the registry entry points at its path.

**MANDATORY, not a suggestion: call these three scripts by their exact
command line, in order. Do not re-derive this mechanism from first
principles, do not improvise your own `herdr pane split`/`tab create`
sequence, and do not write a "basically equivalent" version of your own
launch/wait/collect logic even if it seems simpler for a small run.** A
live test after this warning was already in place still saw the mechanism
re-derived from scratch instead of the scripts being invoked — confirmed by
a run directory (`adhd-run-1/`) that matches no naming convention these
scripts use, and every frame pane stalling on a permission prompt that
`spawn-frames.ts`'s `--permission-mode acceptEdits` flag exists specifically
to prevent (see the spike index, Round 7). If you find
yourself typing a raw `herdr pane split` or `herdr tab create` call for
ADHD branch execution, stop — that means these scripts were skipped. Run:

1. `bun node_modules/@evie-agent/cli/src/evie-agent.ts adhd write-frame-prompts --run-dir <path> --problem "<P>"
--goal-file <path to GOAL.md> [--reference <path> ...]
[--context "..."] --frame "<frameId>|<vantage prompt>" [--frame ...]`
   — writes each frame's full DIVERGENT-mode prompt to
   `<runDir>/<frameId>/prompt.md` on disk (one subfolder per frame — see
   "Directory conventions" in SKILL.md). `--goal-file` is required (ADHD
   only runs during goal refinement, pre-flight Step 0) and `--reference`
   should point at whatever specific goal artifacts (files under the
   goal's own `references/`, prior `grilling/` transcripts, etc) are
   actually relevant to this particular ADHD round — not every file in
   the goal folder reflexively, just the ones that ground this specific
   fork. Do this **regardless of branchExecution mode** (see "Why prompts
   and outputs go to files" in SKILL.md) — under `local-subagents` these
   files are the record of what each branch was told; under `multiplexer`
   they're also what gets read into each pane/tab.
2. `bun node_modules/@evie-agent/cli/src/evie-agent.ts adhd spawn-frames --run-dir <path> --backend herdr
--layout tabs|panes --session <herdr-session> --seed-pane <currentPaneId> --frame
"<frameId>:<promptFile>" [--frame ...]` (use `--layout tabs` unless the
   project config explicitly set `layout: panes`; `--session` is
   REQUIRED — EVA-20: state the herdr session the seed pane lives in
   (`tools.herdr.session`, or the repo-slug default the goals machinery
   derives; the literal `default` = the shared default socket), never
   let an unflagged `herdr` call inherit the default socket where the
   seed pane may not even exist. The session is recorded in
   `manifest.json`, and `collect-frames` rebinds from there) — computes a genuinely
   even N-way split for the panes case (the split math lives in
   `@evie-agent/adhd`'s `herdr-layout` module
   — the seed pane keeps its own space as the orchestrator and is never
   itself used as a frame pane), launches real interactive `claude` in
   each new pane/tab (never `-p`),
   waits for each session to finish booting, then sets a Claude Code
   `/goal` (built-in command, v2.1.139+ —
   https://code.claude.com/docs/en/goal.md) in that session: _"read
   `<promptFile>` and follow it; the goal is met only when `<outputFile>`
   exists and is valid JSON."_ The frame session then self-drives its own
   turns — including recovering from a bad first attempt — until Claude
   Code's own evaluator confirms the file genuinely exists and parses,
   instead of us trusting a plain text reply as a completion signal. Prints
   a `manifest.json` recording frame→pane→file mappings, with each
   `outputFile` resolving to `<runDir>/<frameId>/output.json`. Exact
   shape (from `spawn-frames.ts`), for when a run fails mid-pipeline and
   the manifest has to be read by hand:

   ```json
   {
     "runDir": "<path>",
     "backend": "herdr",
     "layout": "tabs",
     "session": "<herdr-session>",
     "panes": [
       {
         "frameId": "10-year-old",
         "paneId": "<herdr pane id>",
         "promptFile": "<runDir>/10-year-old/prompt.md",
         "outputFile": "<runDir>/10-year-old/output.json"
       }
     ]
   }
   ```

3. `bun node_modules/@evie-agent/cli/src/evie-agent.ts adhd collect-frames --run-dir <path> [--timeout-ms
180000] [--session <herdr-session>]` — rebinds to the session recorded
   in `manifest.json` (`--session` overrides; a pre-EVA-20 manifest
   without one requires the flag) and, for every pane in `manifest.json`,
   blocks on
   `herdr wait agent-status <paneId> --status done` (real event-driven
   wait, not a sleep-based poll loop — confirmed live that a `/goal`-gated
   pane reports `done`, distinct from plain `idle`, once its goal's
   evaluator confirms the condition). `done` is a signal, not proof (same
   lesson as herdr's Claude Code completion-detection findings elsewhere in
   this goal): the script still opens each output file and validates it's
   real JSON before reporting success for that frame. Reads files, never
   scrapes pane transcripts for the actual result content.

**Permission mode: `acceptEdits`, scoped to the launch command only.** A
fresh interactive Claude Code session has no pre-approved permissions, so
without this every frame pane independently stalls on a real permission
prompt ("Do you want to create `<file>.output.json`?") before its first
write — confirmed live, every time, across every frame, before this fix.
`spawn-frames.ts` launches each frame with
`claude --permission-mode acceptEdits` (not `bypassPermissions` —
acceptEdits auto-approves file creates/edits within the pane's working
directory only, which is exactly what a frame needs: read its prompt file,
write its output file, nothing wider). This is a CLI flag on the spawned
process itself, not a settings file dropped into the project or the run
directory — it applies only to that one launch and leaves the rest of the
project's permission posture untouched. Confirmed live: with this flag, a
full frame run completes with zero manual intervention (previously required
approving a prompt in every single pane).

Frame _selection_ (which cognitive frames, how many, wild-card inclusion)
stays a judgment call made by the orchestrating model — only the pane
mechanics are scripted. If a script fails (e.g. `spawn-frames.ts` aborts
before launching anything if the split plan doesn't produce the expected
pane count), report the failure and its exact error rather than falling
back to manual `herdr` calls.

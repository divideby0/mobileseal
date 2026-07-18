# Attribution

Source: [UditAkhourii/adhd](https://github.com/UditAkhourii/adhd)
(`skills/adhd/SKILL.md`), MIT licensed. Local clone for reference:
`~/src/uditakhourii/adhd`.

## What we changed

- **Branch execution is project-configurable across three real strategies**
  — local subagents, multiplexer tabs, or multiplexer panes — read from
  three independent project-config keys (`adhd.branchExecution`,
  `adhd.multiplexer`, `adhd.layout`; the earlier combined
  `adhd.paneStrategy` string was split in Round 8, below) — not hardcoded
  in the skill body. The source skill assumes Claude Code's own `Task`/`Agent`
  tool exclusively throughout, with no notion of separate observable
  processes. This changed twice during design, each time based on empirical
  spikes rather than assumption (see
  `goals/drafts/20260710-214424-goals-workflow/references/agent-teams-tmux-spike-findings.md`
  for the full findings):
  - First pass: local subagents only, with herdr as an escalation for a
    single branch needing real work — reasoned from cost/latency alone,
    before testing.
  - A live spike then proved local `Task` subagents ARE observable while
    running, via Claude Code's own in-pane picker (`↓`/`Enter`) — externally
    readable through `herdr pane read` with no extra integration needed.
    This corrected an initial wrong claim that subagents were
    architecturally invisible while running.
  - A follow-up spike then showed that picker is **sequential-only** — one
    branch's transcript at a time, never all of them simultaneously — which
    is a real, separate limitation from raw observability. True
    simultaneous multi-pane viewing requires independent processes in
    independent panes, which local subagents categorically cannot provide.
  - A further spike (native `teammateMode: tmux` agent-teams) proved
    independent-process, independent-pane execution is a real, working
    pattern elsewhere in Claude Code itself — confirming the mechanism, not
    just the theory.
  - A final spike ran the actual `adhd` skill under herdr and proved the
    `herdr-panes` strategy works end to end (real `herdr pane split` calls,
    real isolated results) — but surfaced that Claude Code defaults to
    non-interactive `claude -p` in a split pane unless explicitly told
    otherwise, which silently defeats observability (a `-p` process runs
    once and exits; nothing stays open to watch). This is now a hard
    warning in Branch execution requiring interactive `claude` for both
    pane-based strategies.

  Net result: all three strategies are real and legitimate trade-offs
  (cost/speed vs. simultaneous observability), so the choice belongs to
  project configuration, the same way review-tool selection belongs to
  project configuration in the `goals` skill — not a single hardcoded
  default asserted without letting the project decide.

- **Added real scripts (the `@evie-agent/adhd` package) for
  `herdr-panes`/`herdr-tabs` mechanics, replacing prose instructions.** The source skill has no
  scripts of its own for its `Task`/`Agent`-call loop (a raw tool call
  needs none), but a live test of the prose-only herdr version (see
  `research/adhd-spike-findings-index.md` (repo root), "Round 4") surfaced real,
  user-caught defects — uneven pane layout and a silent `claude -p` regression
  — that prose warnings alone did not reliably prevent. The package's
  `write-frame-prompts`, `spawn-frames`,
  `collect-frames`, and `herdr-layout` modules now own the
  mechanical parts (even N-way split math, interactive-not-`-p` launch,
  prompt/output file I/O, result collection) deterministically; frame
  _selection_ (which cognitive frames, how many) remains a judgment call
  for the orchestrating model. Two further real bugs (frame launched into
  the seed/orchestrator pane; a wrong prompt-glyph match string) were found
  and fixed by actually running the scripts against a live herdr workspace,
  not just by reading them — this mirrors the upstream project's own
  precedent of having a real, tested `adhd-agent` CLI behind the loop for
  non-Claude-Code use, just scoped here to the herdr-pane mechanics
  specifically.

- **Frame completion is gated by Claude Code's own `/goal` command, not a
  text-marker reply convention** (Round 5, see
  `research/adhd-spike-findings-index.md` (repo root)). Each frame's launch instruction
  under `herdr-panes`/`herdr-tabs` is now `/goal read <prompt file> and
follow it; done only when <output file> exists and is valid JSON` —
  Claude Code's own evaluator (a fast model checking the transcript after
  every turn) enforces this, including retrying if the frame's first
  attempt produces malformed output, rather than trusting a plain
  `FRAME-DONE-<id>` reply string as the original design did. Result
  collection correspondingly moved from a sleep-based file-existence poll
  loop to a real event-driven `herdr wait agent-status --status done`
  block per pane (confirmed live: a `/goal`-completed pane reports `done`,
  distinct from plain `idle`, which can also mean "stuck at a prompt").
  `done` is treated as a signal, not proof — the collector still opens and
  parses each output file before trusting it, same discipline as the
  broader goal's herdr-completion-detection research. A real send-text/
  Enter timing race (the `/goal` command could land in the composer without
  actually being submitted) was found and fixed during this round's live
  testing. Not present in the source skill at all — it has no
  completion-gating concept because its `Task`/`Agent` calls return
  synchronously.

- **Closed the permission-prompt gap with `--permission-mode acceptEdits`,
  scoped to the spawned launch command.** Every frame pane previously
  stalled on a real Claude Code permission prompt before its first write,
  with no pre-approval. `spawn-frames.ts` now launches each frame with
  `claude --permission-mode acceptEdits` — auto-approves file creates/edits
  within that pane's own working directory only, deliberately narrower than
  `bypassPermissions`. Also added `herdr agent rename` alongside the
  existing `pane rename` call so frame sessions are identifiable by name in
  herdr's sidebar agent list. Confirmed live: full pipeline runs with zero
  manual intervention. See `research/adhd-spike-findings-index.md` (repo root), Round 6.

- **ADHD is now hard-gated to goal-refinement context only — it never runs
  standalone.** A user correction clarified the intended flow more
  precisely than the skill implemented: every run must be grounded in a
  real `GOAL.md` (Step 0 in the pre-flight gate, checked even before
  explicit `/adhd` invocation), every frame's prompt now includes real
  goal-artifact file paths (`--goal-file`/`--reference` on
  `write-frame-prompts.ts`) instead of a bare free-text problem statement,
  and every run's files live nested under that goal's own folder
  (`{goal-subfolder}/adhd/session-NNN-YYYYMMDD-HHmmSS/{frame-name}/
{prompt.md,output.json}` — one subfolder per frame, not a flat
  `<frameId>.prompt.md` file). None of this exists in the source skill,
  which has no concept of a goal at all. Also split the combined
  `adhd.paneStrategy: herdr-panes|herdr-tabs` config value into three
  independent keys (`branchExecution`, `multiplexer`, `layout`) so a
  future non-herdr multiplexer backend doesn't require inventing a whole
  new parallel set of strategy strings. See
  `research/adhd-spike-findings-index.md` (repo root), Round 8.

- **`herdr-tabs` is now the recommended/default herdr mechanism, not
  `herdr-panes`.** A real user test showed a 3-way pane split visibly
  cramped and hard to read. The same test also revealed that the
  "use the scripts" instruction (Round 4) wasn't forceful enough — CC
  re-derived the pane-splitting/launch mechanism from scratch instead of
  calling `spawn-frames.ts`, which is why the Round 6 permission fix never
  took effect on that run (evidenced by a run directory name matching no
  convention the scripts use). Upgraded that instruction to an explicit
  MANDATORY directive with a concrete trip-wire. Separately, live-testing
  `herdr-tabs` for the first time (previously only code-reviewed, not run)
  surfaced a real bug: `herdr agent rename` requires globally unique names
  across the whole herdr server, and a second run reusing frame ids from an
  earlier still-open run failed with `agent_name_taken`. Fixed by scoping
  every pane/agent name to `adhd:<runId>:<frameId>` (a short hash derived
  from `runDir`) and making the rename call best-effort rather than fatal.
  None of this is present in the source skill, which has no pane/naming
  concept at all. See `research/adhd-spike-findings-index.md` (repo root), Round 7.

- **Added a pre-flight check (Step 2.4): don't re-run against an
  already-converged decision.** ADHD is for genuinely open forks, not for
  relitigating something `grill-me` already resolved. Not present in the
  source — added because this skill sits inside a lifecycle (`goals`) that
  has its own convergence discipline, and running ADHD after convergence
  would work against that discipline rather than serve it.
- **Added an explicit "Relationship to `grill-me` and `goals`" section**
  describing how this skill is actually invoked in evie-agent — usually as
  a pause-and-resume inside `grill-me`'s interview flow or the `goals`
  skill's ideation step, not as a standalone first move. The source skill
  is invocation-agnostic (works fine as a freestanding `/adhd` command);
  we kept that (explicit `/adhd` invocation still works, per pre-flight
  Step 1), but documented the more common integrated path too.
- The two-phase diverge/focus loop, all 15 cognitive frames, frame-picking
  heuristics, output shape, anti-patterns, and calibration guidance are
  preserved from the source in substance — the core mechanic (parallel
  isolated generation, then score/cluster/deepen) is the whole value of the
  skill and needed no changes to its logic. Wording in the loop steps was
  updated to say "branch" instead of "subagent"/"Agent" throughout, since a
  branch is no longer always a subagent call under this skill's
  configurable execution strategy.
- Did not port the companion `adhd-agent` npm CLI section — that's an
  outside-Claude-Code batch tool, out of scope for a Claude Code skill file
  in this repo. The GitHub link is preserved in the skill body header for
  anyone who wants it.

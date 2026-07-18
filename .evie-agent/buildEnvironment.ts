// Per-worktree environment hook (evie-agent, EVA-24).
//
// Make a goal's execution worktree GENUINELY independent of its siblings
// (isolated compose project, own database/schema, own ports), then assert
// it: `isolated: true` is what lets goals run in parallel. Returning
// `{ isolated: false }` (this stub) makes no assertion, and the
// orchestrator keeps the cautious default — one goal at a time.
//
// Contract (types: `BuildEnvironment` in @evie-agent/goals):
//   - this call must stay CHEAP and side-effect-free;
//   - `apply()` does the real work at goal launch and returns the env
//     vars injected into the executor (label everything it creates with
//     `ctx.key`, and reap stale leftovers for that key FIRST —
//     reap-then-create is what makes crashes self-heal);
//   - `teardown()` reaps at merge cleanup; it must be idempotent.
// The `ctx` toolkit provides readSource/writeOverlay (gitignored
// generated files), reservePorts (held), portFor (deterministic), and
// env/TOML helpers.
export default function buildEnvironment() {
  return { isolated: false };
}

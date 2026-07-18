# Attribution

Source: [mattpocock/skills](https://github.com/mattpocock/skills)
(`skills/engineering/domain-modeling`), adapted for evie-agent.

## What we changed

- **Retargeted the file layout onto this monorepo's multi-context shape**:
  per-package `CONTEXT.md` glossaries under `packages/<pkg>/`, a root
  `CONTEXT-MAP.md` index, and ADRs at both root (`docs/adr/`, cross-package)
  and package level (`packages/<pkg>/docs/adr/`). Upstream assumes a
  single-context project.
- **Lazy file creation** spelled out explicitly (create CONTEXT.md on the
  first resolved term, CONTEXT-MAP.md once a second package has one) —
  upstream leaves creation timing implicit.
- **Worked examples rewritten against real evie-agent domain language**
  (AgentSession `done` vs `idle`, orchestrator vs executor roles,
  `waitForState` semantics) instead of upstream's generic examples.
- **Three-part ADR gate** (hard to reverse + surprising without context +
  real trade-off, all required) kept in substance but framed as an
  offer-sparingly rule integrated with this repo's grill-me interview flow.
- **Added a per-project `docs/adr/BACKLOG.md`** for dated repo-state
  backfill candidates, so the skill body stays instructional and stable
  (originally a `references/adr-backlog.md` inside this folder; moved
  into the project in EVA-14 when the skill became distributed —
  per-repo working state can't live in a shared skill folder).

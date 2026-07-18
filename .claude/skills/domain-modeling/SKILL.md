---
name: domain-modeling
description: Build and sharpen the project's domain model — the active discipline of CHANGING the model, not just reading it for vocabulary. Use when pinning down terminology or a ubiquitous language ("what should we call this?"), writing or updating a package CONTEXT.md glossary or the root CONTEXT-MAP.md, recording an architectural decision as an ADR under docs/adr/, or when another skill (grill-me, or the goals skill's wayfinder mode) needs to maintain the domain model.
---

# Domain Modeling

Actively build and sharpen the project's domain model as you design. This is
the _active_ discipline — challenging terms, inventing edge-case scenarios,
and writing the glossary and decisions down the moment they crystallize.
Merely _reading_ `CONTEXT.md` for vocabulary is not this skill — that's a
one-line habit any skill can do. This skill is for when you're **changing**
the model, not just consuming it.

Adapted from [mattpocock/skills](https://github.com/mattpocock/skills)
(`skills/engineering/domain-modeling`), aligned to a package-per-context
monorepo layout.

## File structure

A monorepo has multiple bounded contexts (one per package), so it uses
the multi-context shape (a single-context repo collapses this to one
root `CONTEXT.md` + `docs/adr/`):

```
{repo}/
├── CONTEXT-MAP.md              # points to each package's context
├── docs/adr/                   # cross-package / architectural decisions
│   ├── 0001-some-decision.md
│   └── ...
└── packages/
    ├── billing/
    │   ├── CONTEXT.md          # Invoice, Ledger, Reconciliation, ...
    │   └── docs/adr/           # package-local decisions
    ├── catalog/
    │   └── CONTEXT.md
    └── ...
```

Create files lazily — only when you have something to write. If a package
has no `CONTEXT.md` yet, create one when the first term is resolved for that
package. If `docs/adr/` doesn't exist yet (package-local or root), create it
when the first ADR is needed. If `CONTEXT-MAP.md` doesn't exist yet, create
it once a second package gets its own `CONTEXT.md`, using exactly this
shape (an index, nothing else — one line per bounded context):

```markdown
# Context Map

| Package          | Bounded context (one line)         | Glossary                                  |
| ---------------- | ---------------------------------- | ----------------------------------------- |
| packages/billing | Invoices, ledgers, reconciliation. | [CONTEXT.md](packages/billing/CONTEXT.md) |

Cross-package relationships worth naming (shared kernels, upstream/
downstream) get one bullet each below the table.
```

## During the session

### Challenge against the glossary

When the user (or another agent's output) uses a term that conflicts with a
package's `CONTEXT.md`, call it out immediately. E.g.: "`coding-agent`'s
context defines `done` as finished-and-not-yet-seen, `idle` as
finished-and-seen — you said 'idle' but described the not-yet-seen case,
which is `done`. Which do you mean?"

### Sharpen fuzzy language

When vague or overloaded terms show up, propose a precise canonical term.
"You're saying 'the agent' — do you mean the orchestrator (whoever the user
is directly talking to) or the executor (the Claude Code session doing
plan+execute work)? Those are different roles in this system."

### Discuss concrete scenarios

Stress-test domain relationships with specific scenarios. For example: "If a
promoted goal turns out to be too big for one execution session — does it
become a `wayfinder` map with the original goal as the map's destination, or
does it split into multiple sibling goals? Walk me through both."

### Cross-reference with code

When someone states how something works, check whether the code agrees. If
you find a contradiction, surface it: "You said `waitForState` resolves the
instant the target state is reached, but `session.ts` documents that it may
resolve with a _different_ state if the agent already moved on (e.g. `done`
flipping to `idle` once seen) — which is right?"

### Update CONTEXT.md inline

When a term is resolved, update the relevant `CONTEXT.md` right there. Don't
batch these up — capture them as they happen. Format:

```markdown
## <Term>

<One or two sentences, precise and unambiguous. Cross-reference related
terms by name.>
```

`CONTEXT.md` is a glossary and nothing else — no implementation details, no
scratch notes, no decisions-with-rationale (that's an ADR's job).

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful.
2. **Surprising without context** — a future reader will wonder "why did they
   do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and
   one got picked for specific reasons.

If any is missing, skip the ADR. Format (numbered, package-local or root
`docs/adr/`):

```markdown
# <NNNN>. <Title>

**Status:** accepted | superseded by <NNNN> | deprecated

## Context

<The situation and forces at play.>

## Decision

<What was decided.>

## Consequences

<What this makes easier or harder; what it forecloses.>
```

## ADR backfill candidates

A project may keep a dated list of known decisions worth backfilling as
ADRs in `docs/adr/BACKLOG.md` (repo working state — it lives in the
project, never inside this skill folder, which is shared across
projects). If it exists, read it (and strike entries) whenever this
skill runs against an area it names; create it lazily when a backfill
candidate first surfaces.

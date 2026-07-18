# Wayfinder mode (oversized ideas)

The goals skill's planning mode for ideas too big for one execution
session. Read this in full whenever the body's "Wayfinder mode" pointer
sends you here: charting a new map, working through an existing one, or
recrafting a map forward after a goal locks. Heading levels below match
the section's original in-body form so existing cross-references ("see
The Map", "One execution loop at a time") stay recognizable.

Contents:

- [What a map is, and when to chart one](#what-a-map-is-and-when-to-chart-one)
- [Plan, don't do](#plan-dont-do)
- [Refer by name](#refer-by-name)
- [The Map](#the-map) — the canonical `MAP.md` body
- [One execution loop at a time (hard rule)](#one-execution-loop-at-a-time-hard-rule)
- [Ticket Types](#ticket-types)
- [Fog of war](#fog-of-war)
- [Out of scope](#out-of-scope-1) — the discipline (the map body's own
  `## Out of scope` section shares the slug)
- [Invoking wayfinder mode](#invoking-wayfinder-mode) — chart vs work-through, step by step

## What a map is, and when to chart one

If, during drafting, breadth-first grilling reveals real fog (open questions
that keep spawning further open questions, not resolvable in one execution
session) — a judgment call made during `grill-me`, not a mechanical
threshold on word/question count — don't force the idea into one oversized
goal. Chart it as a **wayfinder map** instead: a shared map of investigation
tickets on Linear, resolved one at a time until the way to the destination
is clear.

A wayfinder map is a _planning_ structure that rides along with the goals
it spawns. It exists to answer "what should we build" at a scale bigger
than a single goal's draft phase can hold. Once every ticket is resolved
or ruled out of scope AND `## Not yet specified` is empty (an empty
frontier alone can still hide blocked tickets or unresolved fog), what's
left is one or more clearly-scoped goals ready to draft and promote
through the normal lifecycle — a ticket that resolves into "now we know
enough to build X" becomes its own promoted goal, executed the usual way.

Local file tree by default, Linear lazily: the map lives as `MAP.md` in
the **currently-active goal's own `wayfinder/` subfolder** and rolls
forward — when that goal completes and locks, the next goal's draft
recrafts the map from the locked snapshot. Linear issues are created
**lazily**: a ticket gets a real issue only when the agent/user decide
(after a goal completes) that it has firmed up enough to become a goal,
which then promotes through the normal lifecycle. Where the map lives
should eventually be a per-project config axis (local file tree vs.
tracker-canonical, matching upstream wayfinder's pluggable trackers);
local is the default and the only mode in this pass.

### Plan, don't do

Wayfinder mode is **planning** by default: each ticket resolves a decision,
and the map is done when the way is clear — nothing left to decide before
someone executes. The pull to just do the work is usually the signal you've
reached the edge of the map and it's time to hand off to this skill's normal
execution phase (Lifecycle steps 5–8 in SKILL.md). An effort can override this in its
**Notes** — carrying execution into the map itself — but absent that,
produce decisions, not deliverables.

### Refer by name

Every map and ticket has a **name** — its title. In narration and the
map's Decisions-so-far, refer to it by that name, never by a bare Linear
ID or slug. A wall of `ABC-42, ABC-43, ABC-44` is illegible; names read at
a glance. When a ticket is backed by a Linear issue, the ID and URL don't
vanish — the name wraps its link — but they ride _inside_ the name, never
stand in for it.

### The Map

The map is `wayfinder/MAP.md` in the currently-active goal's folder — the
canonical artifact. Longer supporting detail for tickets lives beside it
in `wayfinder/references/`.

The map is an **index**, not a store. It gists each decision in one line
and links to where the detail lives (a resolved ticket's goal folder, a
research doc, a grilling transcript); it never restates detail at length.

**The map body:**

```markdown
## Destination

<what reaching the end of this map looks like — the spec, decision, or
change this effort is finding its way to. One or two lines; every session
orients to it before choosing a ticket.>

## Notes

<domain; skills every session should consult (e.g. domain-modeling,
grill-me); standing preferences for this effort>

## Tickets

<!-- open questions, one per line, each sized to one session; the frontier
     is the unblocked ones. longer notes go in wayfinder/references/ -->

- **<ticket name>** (<research|prototype|grilling|task>, <XS–XXL>) —
  <the question this ticket resolves> (blocked by: <ticket name>, …)

## Decisions so far

<!-- the index — one line per resolved ticket -->

- [<resolved ticket name>](link-to-detail) — <one-line gist of the answer>

## Not yet specified

<!-- fog of war: in-scope but not yet sharp enough to ticket -->

## Out of scope

<!-- work ruled beyond the destination; closed, never graduates -->
```

Open tickets **are** listed in the map body's `## Tickets` — with no
tracker to query, `MAP.md` is the single surface. (In the deferred
tracker-canonical mode, open tickets would instead be sub-issues found by
query, per upstream wayfinder.)

**Tickets:** each ticket is one entry in `## Tickets` — a name, a type
(`research` | `prototype` | `grilling` | `task`, see Ticket Types below),
an effort size, the question it resolves (sized to one session), and any
`blocked by:` notes. A ticket is **unblocked** when everything blocking
it is resolved; the **frontier** is the open, unblocked tickets — the
edge of the known.

**Size tickets (and the map) in relative effort, never calendar time**
(EVA-21, the goals SKILL.md convention): t-shirt sizes on the fixed
Fibonacci scale — XS=1, S=2, M=3, L=5, XL=8, XXL=13. "Sized to one
session" bounds a ticket's scope; the size records how heavy that
session is expected to be relative to the map's other tickets. A
"6-week phase" on a map is the estimate smell this rule exists to
kill — an XXL entry is a signal to split, not to schedule.

Locally, no claim mechanic is needed: the map travels with the single
active goal, and execution is one loop at a time. When a ticket is lazily
promoted to a real Linear issue (because it's becoming a goal), it gets a
`wayfinder:<type>` label, uses Linear's native issue-relation blocking,
and claiming is by assignee — upstream's conventions apply from there.

The answer isn't part of the ticket's entry — it's recorded on resolution
(see Work through the map). Assets created while resolving a ticket
(research docs, prototypes) are linked from the map, not pasted in — and if
they're durable project-level artifacts, they belong in `research/` or a
package's `references/`, per the directory conventions in SKILL.md, with the map
(and the Linear issue, if one exists) linking to them (ideally as a git
permalink with commit hash baked in, same convention as goal promotion).

### One execution loop at a time (hard rule)

A map may define multiple tickets/steps up front or as fog graduates. **Only
one of those tickets is ever backed by a live execution loop (goal folder +
herdr Claude Code session) at a time** — the map rolls forward through one
locked snapshot at a time, so a second concurrent loop would fork the map's
history and race the first for branches, worktrees, and reviewer tabs.
Never spawn concurrent execution
infrastructure for tickets that aren't the one currently being worked, even
if their questions are already sharp enough to specify.

A ticket's own definition (its question line in `## Tickets`, plus any
supporting notes in `wayfinder/references/`) is
cheap to write down early and does **not** violate this rule — planning
ahead is expected. What's constrained is _execution_: a ticket doesn't get a
goal folder, a branch/worktree, or a spawned Claude Code session until it's
its turn.

The map travels with the active goal: `wayfinder/MAP.md` + `references/`
live in the goal currently being worked. When that goal completes and its
folder locks (per the frontmatter lifecycle's completion rule in SKILL.md),
the map snapshot locks
with it — nothing is stranded, because the map is **recrafted forward, not
edited in place**: the next goal's draft begins by rewriting the map from
the previous goal's locked snapshot, referenced by relative path and git
permalink, never copied wholesale. Fold in what execution actually
revealed (`results/RESULT.md`, friction encountered, code that didn't
match assumptions), not just the resolved ticket's headline answer. The
chain of locked `wayfinder/` snapshots is the map's history; the newest
goal holds its current state.

### Ticket Types

Every ticket is either **HITL** — human in the loop, worked _with_ the user,
who speaks for themselves — or **AFK**, driven by the agent alone. A HITL
ticket only resolves through that live exchange; the agent never answers its
own question on the user's behalf (a grilling ticket that answers itself has
broken this).

- **Research** (AFK): reading docs, third-party APIs, or local resources.
  Ground first, spend second: run the grounding ladder (repo evidence,
  then the project's `tools.memory.*` sources — `evie-agent hindsight
recall` for episodic memory, configured file trees by their
  descriptions) before any paid run; a ticket the ladder fully answers
  resolves without touching Exa. For the paid half, use the `research`
  skill (`evie-agent research draft|start|…` — author the `--input`
  JSON first, per its #1 rule). Ticket resolution = the research run
  lands at the project's `storage.research` destinations (local drafts
  under `research/`, plus the Notion mirror when configured) and the
  map links the artifact. **The map is the consent boundary**: a
  charting-ratified research ticket MAY draft and execute autonomously
  within its stated question/scope when the project sets
  `research.autoExecute: true` — drafting is always permitted either
  way; with the default `false`, execution waits for explicit go-ahead
  like standalone research. A ticket definition may carry an optional
  `effort` field (the pipeline's effort levels; the project's
  `research.effort` is the default when absent) and auto-execute must
  refuse to exceed it.
- **Prototype** (HITL): a cheap, rough, concrete artifact to react to — an
  outline, a stub, a UI/logic sketch. Links the prototype as an asset. Use
  when "how should it look/behave" is the key question.
- **Grilling** (HITL): conversation via the `grill-me` skill (which folds in
  `domain-modeling`), one question at a time. The default case.
- **Task** (HITL or AFK): work that must happen before a _decision_ can be
  made — nothing to decide, prototype, or research, but discussion is
  blocked until it's done (provisioning access, moving data so its shape can
  be seen). The one type that _does_ rather than decides — earns its place
  by unblocking a decision, not delivering the destination. AFK where the
  agent can drive it alone; otherwise HITL with a precise checklist.
  Resolved when the work is done; the answer records what was done and any
  resulting facts (credential location, new URLs, row counts) later tickets
  depend on.

### Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see.
Beyond the live tickets lies the **fog of war** — decisions and
investigations you can tell are coming but can't yet pin down, because they
hang on questions still open. Resolving a ticket clears the fog ahead of it,
graduating whatever's now specifiable into fresh tickets — one at a time,
until no tickets remain.

**Fog or ticket?** The test is whether you can state the question precisely
now — _not_ whether you can answer it now.

- **Ticket when** the question is already sharp, even if blocked.
- **Not yet specified when** you can't yet phrase it that sharply.

### Out of scope

Fog only ever gathers _toward_ the destination. Work beyond it is **out of
scope** — its own section, not fog. Out-of-scope work never graduates; it
returns only as a fresh effort if the destination is redrawn.

When an existing ticket turns out to sit past the destination, close it and
leave one line in **Out of scope**: the gist plus why, linking the closed
ticket. It stays out of **Decisions so far**.

### Invoking wayfinder mode

Two sub-modes. Either way, **never resolve more than one ticket per
session** — every resolution reshapes the map (graduating fog, adding or
invalidating tickets), so a second resolution in the same session would act
on a map the first one just made stale.

**Chart the map** — user invokes with a loose idea that turned out too big
for one execution session:

1. **Name the destination.** Run `grill-me` (which pulls in `domain-modeling`
   as needed) to pin down what this map is finding its way to. The
   destination fixes the scope — settle it first.
2. **Map the frontier.** Grill again, **breadth-first**: fan out across the
   whole space rather than deep on one thread, surfacing open decisions and
   first steps takeable now. **If this surfaces no fog** — the way is
   already clear, small enough for one session — stop; you don't need a map,
   just draft the goal directly (Lifecycle step 1 in SKILL.md).
3. **Create the map** as `wayfinder/MAP.md` in the goal folder that
   triggered it: Destination and Notes filled in, Decisions-so-far empty,
   fog sketched into **Not yet specified**.
4. **Write down the tickets you can specify now** in the map's
   `## Tickets`, with `blocked by:` notes where ordering matters.
   Everything you can't yet specify stays in the fog. No Linear issues
   yet — tickets get issues lazily, when they become goals.
5. Stop — charting is one session's work; do not also resolve tickets.

**Work through the map** — user invokes with a map (the path of the goal
folder currently carrying it). A ticket name is optional — without one,
you pick the next decision, not the user:

1. Load the map's low-res body — `wayfinder/MAP.md` in the newest goal of
   the chain — not every ticket's detail.
2. Choose the ticket. If named, use it. Otherwise take the first frontier
   ticket in `## Tickets` order.
3. Resolve it — zoom as needed: read any related or resolved ticket's
   detail on demand (its goal folder, research doc, or transcript); invoke
   the skills the `## Notes` block names (typically `grill-me`, sometimes
   `domain-modeling` directly).
4. Record the resolution: write the answer where its detail lives (goal
   folder, `wayfinder/references/`, or `research/`), remove the ticket
   from `## Tickets`, and append a one-line gist to the map's
   Decisions-so-far. If the ticket has a Linear issue, also post the
   answer as a resolution comment there and close it.
5. Add newly-surfaced tickets (create-then-wire); graduate any fog the
   answer made specifiable, clearing it from **Not yet specified**. If a
   ticket (this one or another) turns out to sit beyond the destination,
   rule it out of scope rather than resolving it. If the decision
   invalidates other parts of the map, update or delete those tickets.

   **If the ticket just resolved was goal-backed** (its resolution came from
   a promoted-and-executed goal, not just a grilling/research/task ticket),
   base this reformulation on more than the resolution comment alone — read
   that goal's `results/RESULT.md` and consider what execution actually
   revealed: implementation friction, code that didn't match assumptions
   made when the ticket was written, anything that surfaces new fog or
   invalidates a ticket that looked fine on paper. Goal execution surfaces
   things a plain grilling ticket wouldn't; don't reformulate on the
   headline resolution alone when a full execution trace is available.

   This reformulation always happens at the **map** level, by whoever
   resumes work on the map next — never by the goal that just completed and
   locked (it cannot reach back and edit the map itself).

Multiple _planning_ tickets (grilling, research) may be resolved across
sessions, but a local map is inherently serial — it travels with the
single active goal. Concurrent multi-session planning belongs to the
deferred tracker-canonical mode. **Execution remains one-loop-at-a-time**
regardless (see "One execution loop at a time" above).

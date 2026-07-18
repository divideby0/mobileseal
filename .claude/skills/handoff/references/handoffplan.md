# Handoffplan Mode (handoff + executable plan)

Escalation mode for turning a handoff into an executable plan for the next
session. Read this only when the trigger in SKILL.md's "Escalation:
handoff + plan" section fires — it extends a completed handoff; it never
replaces one.

Do the full handoff (SKILL.md Steps 1–7) first, unabridged, then:

1. Write a paired `plan-<YYYYMMDD-HHmmSS>-<slug>.md` **next to** the
   handoff (same directory, same slug, datestamp first). The plan is an
   _action_ document — phased, specific enough to execute without the
   conversation, each phase tracing back to evidence in the handoff ("See
   Evidence & Data in {handoff file}" rather than duplicating tables).
   Include per-phase Files/Validates-with/Rollback, an Anti-Goals section
   (approaches explicitly rejected and why, pulled from the handoff's What
   We Tried / Key Decisions), and a Quick Start with the single first
   concrete action.
2. Commit current work (surgically — only files this session touched).
3. Output a ready-to-paste prompt for the next session: point it at both
   files, tell it to start Phase 1 immediately, and say explicitly **not**
   to onboard or re-explore — the plan has everything.
4. This mode always closes the session — the point is a fresh session
   executes with clean context, not that this session keeps going.

This mirrors REMvisual's `claude-handoff` plugin's separate `handoffplan`
skill; we fold it in as a mode of `handoff` rather than a fifth skill,
since it's the same mining process with a different Step 5+ ending. See
`references/attribution.md`.

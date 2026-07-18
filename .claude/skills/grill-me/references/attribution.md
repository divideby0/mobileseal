# Attribution

This skill merges three skills from
[mattpocock/skills](https://github.com/mattpocock/skills) into one:

- `skills/productivity/grilling` — the core one-question-at-a-time interview
  mechanic with a recommended answer per question.
- `skills/productivity/grill-me` — a one-line alias that just invoked
  `grilling`.
- `skills/engineering/grill-with-docs` — `grilling` + `domain-modeling`
  together.

We kept the name `grill-me` (per user preference) but gave it `grilling`'s
actual interview mechanic, and folded in `domain-modeling` as an
always-available capability triggered by terminology conflicts or
hard-to-reverse decisions surfacing mid-interview, rather than a separate
skill name to choose between. We also require `AskUserQuestion` for every
question, which none of the three source skills specified (they predate or
don't assume that tool).

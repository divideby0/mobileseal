# Handoff Self-Validation Checklist

Run after the Step 5 write. Do not skip.

## 1. Line Count Check

Check your system prompt for context window size. Target the ceiling, not
the floor.

| Pass                  | Minimum | Target ceiling | Must expand if under |
| --------------------- | ------: | -------------: | -------------------: |
| Quick (Standard/200K) |     150 |            400 |                  150 |
| Quick (Extended/1M)   |     250 |            800 |                  250 |
| Deep                  |     300 |            600 |                  300 |

**Under the must-expand threshold:** go back to Step 4's gap pass. Read your
file back. Scan the conversation again for uncaptured data. Use `Edit` to
append. Do not proceed until above threshold.

**Between threshold and ceiling:** the gap pass is still worth doing — there
is almost certainly data you missed.

Common thin-section culprits:

- "Where We Are" has fewer than 10 bullets
- "What We Tried" is missing or has only 1-2 entries
- "Evidence & Data" summarizes instead of giving numbers
- "Key Decisions" has only one entry
- "Code Analysis" is missing when source was actually read this session

## 2. Data Completeness Check

- [ ] "Where We Are" includes specific file AND function/symbol names
- [ ] "What We Tried" has one entry per distinct approach discussed
- [ ] "Evidence & Data" has actual numbers, not summaries ("39/39 tests
      passing" not "tests pass")
- [ ] "Key Decisions" includes at least one rejected alternative
- [ ] If prior handoffs exist on this chain: clear "what changed since last
      time"
- [ ] "Quick Start" has a concrete first action, not "continue working"
- [ ] Data file paths included so the next session can reference raw results

## 3. Chain Check

- [ ] **Chain** line has a valid tag (goal/loop-folder slug, or a standalone
      hex)
- [ ] If continuation: **Parent** file actually exists (`ls` to verify, don't
      assume)
- [ ] **Prior chain** breadcrumb lists all ancestors in order
- [ ] If seq 1: Parent = `none — first in chain`

## 4. Split Check

Over ceiling and still growing? Split into `part1` + `part2` with
cross-references rather than one unbounded file.

## 5. If any check fails

Fix before Step 7 (report). Rewrite thin sections rather than shipping a
handoff that fails its own checklist — the next session inherits whatever
gaps you leave here.

## 6. Record the trace (after everything above passes)

Fill the handoff's `## Self-Check` section. What it records — the five
entries and the honesty rules (write it last, yellow-flag claims, what
belongs in "Not captured") — is specified once, in `output-template.md`'s
Self-Check block; follow that, don't reconstruct the list here.

# CodeRabbit AI prompts

Per-finding AI prompts saved by the CLI with the review in
FINDINGS.md, captured by a second `coderabbit review --show-prompts`
invocation (EVA-31). RECORDED as reconciliation aid \u2014 understanding
why CodeRabbit flagged a finding, tuning `--config` instructions \u2014
and NEVER executed directly (the autofix rule).

Replaying 1 AI prompt from your last review on CED-16-still-decode-fidelity.

────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-16-still-decode-fidelity/goals/CED-16-still-decode-fidelity/GOAL.md:41goals/CED-16-still-decode-fidelity/GOAL.md:41-42]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @goals/CED-16-still-decode-fidelity/GOAL.md around lines 41 - 42,
  Update the raw-dictionary key reference in the StillDecoder-related
  documentation or implementation to use the valid ImageIO symbol
  kCGImagePropertyRawDictionary instead of
  kCGImageSourcePropertyRawDictionary, preserving the intended raw metadata
  distinction.


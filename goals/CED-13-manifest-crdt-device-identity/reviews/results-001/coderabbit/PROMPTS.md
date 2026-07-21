# CodeRabbit AI prompts

Per-finding AI prompts saved by the CLI with the review in
FINDINGS.md, captured by a second `coderabbit review --show-prompts`
invocation (EVA-31). RECORDED as reconciliation aid \u2014 understanding
why CodeRabbit flagged a finding, tuning `--config` instructions \u2014
and NEVER executed directly (the autofix rule).

Replaying 6 AI prompts from your last review on CED-13-manifest-crdt-device-identity.

────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-13-manifest-crdt-device-identity/App/MobileSeal/Support/UITestSupport.swift:54App/MobileSeal/Support/UITestSupport.swift:54-56]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/Support/UITestSupport.swift around lines 54 - 56,
  Update the fixture-copy operation in the UI-test support setup to stop
  suppressing errors: remove the try? around FileManager.default.copyItem
  and propagate the thrown failure or explicitly fail fast. Ensure missing,
  unreadable, or uncopyable v0 fixtures prevent the migration test from
  continuing without seeded data.


────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-13-manifest-crdt-device-identity/Sources/VaultCore/SealedVault.swift:430Sources/VaultCore/SealedVault.swift:430-431]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @Sources/VaultCore/SealedVault.swift around lines 430 - 431, Update the
  recovery selection condition around bestV1 and bestV0 so a v1 candidate is
  selected when its localRevision equals the best v0 generation, changing
  the strict comparison to an inclusive one while preserving v1 preference
  for ties.


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-13-manifest-crdt-device-identity/goals/CED-13-manifest-crdt-device-identity/GOAL.md:98goals/CED-13-manifest-crdt-device-identity/GOAL.md:98-105]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @goals/CED-13-manifest-crdt-device-identity/GOAL.md around lines 98 -
  105, Update the “On-disk graph defined” description to state that each
  complete encrypted manifest snapshot embeds the trust list directly,
  rather than containing a trust list reference. Keep the existing snapshot,
  HEAD, recovery, and local-generation requirements unchanged.


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-13-manifest-crdt-device-identity/App/MobileSeal/Support/KeychainDeviceKeyStore.swift:85App/MobileSeal/Support/KeychainDeviceKeyStore.swift:85-114]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/Support/KeychainDeviceKeyStore.swift around lines 85 -
  114, Update the keyData cleanup in the key-creation flow around baseQuery
  and the deferred zeroization so the attributes dictionary no longer
  retains kSecValueData before keyData is cleared. Remove the dictionary’s
  kSecValueData entry after SecItemAdd (including all return and error
  paths) or otherwise ensure unique storage, then let the existing defer
  zeroize the original buffer.


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-13-manifest-crdt-device-identity/CONTEXT.md:51CONTEXT.md:51-56]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @CONTEXT.md around lines 51 - 56, Update the Tombstone contract
  documentation to explicitly state how entry-scoped tombstones remove the
  entire media aggregate: either define deterministic coordinator expansion
  into tombstones for every linked asset, or encode an equivalent
  aggregate-deletion rule. Ensure thumbnails and Live-Photo videos are
  covered, and add a test verifying all linked assets are deleted.


────────────────────────────────────────────────────────────────────────
  minor [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-13-manifest-crdt-device-identity/Sources/VaultCore/RollbackStateStore.swift:58Sources/VaultCore/RollbackStateStore.swift:58-65]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @Sources/VaultCore/RollbackStateStore.swift around lines 58 - 65,
  Update RollbackStateStore.load() to treat only a missing state file as an
  empty State; propagate all other Data(contentsOf:) read failures as
  VaultError.ioFailure for the rollback-state path. Preserve the existing
  JSON decoding error handling and first-run behavior for a nonexistent url.


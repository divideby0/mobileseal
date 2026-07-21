# CodeRabbit AI prompts

Per-finding AI prompts saved by the CLI with the review in
FINDINGS.md, captured by a second `coderabbit review --show-prompts`
invocation (EVA-31). RECORDED as reconciliation aid \u2014 understanding
why CodeRabbit flagged a finding, tuning `--config` instructions \u2014
and NEVER executed directly (the autofix rule).

Replaying 4 AI prompts from your last review on CED-15-media-export-share-import.

────────────────────────────────────────────────────────────────────────
  major [Stability & Availability]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/App/MobileSeal/Export/ExportController.swift:80App/MobileSeal/Export/ExportController.swift:80-131]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/Export/ExportController.swift around lines 80 - 131,
  Add a teardown generation/state check around the stage() completion path
  after await task.value and before assigning activeBatch, using the
  controller’s existing teardown coordination symbols or a generation
  counter. Have tearDownExports() invalidate the current generation, and
  make stage() remove the batch directory and throw cancellation when its
  captured generation is stale; retain the existing files(exist:) validation
  for non-racing failures.


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/App/MobileSeal/Import/InboxMediaProvider.swift:23App/MobileSeal/Import/InboxMediaProvider.swift:23-41]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/Import/InboxMediaProvider.swift around lines 23 - 41,
  After FileManager.default.copyItem succeeds in the staging flow,
  revalidate dest with Self.length and MediaHashing.blake2b256Hex before
  appending StagedPart. Compare both values against part.byteLength and
  part.blake2b256, throwing MediaProviderError.integrityMismatch on
  mismatch; keep the existing source validation and copy error handling
  unchanged.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/Tests/VaultCoreTests/MediaHashingTests.swift:24Tests/VaultCoreTests/MediaHashingTests.swift:24-28]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @Tests/VaultCoreTests/MediaHashingTests.swift around lines 24 - 28,
  Update the data-generation loop in the media hashing test to create more
  than 1,048,576 bytes, ensuring the input crosses the 1 MiB streaming
  buffer boundary and exercises multiple read iterations. Preserve the
  existing deterministic byte pattern.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/App/ShareInbox/InboxWriter.swift:188App/ShareInbox/InboxWriter.swift:188-232]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/ShareInbox/InboxWriter.swift around lines 188 - 232, Update
  stageLivePhotoBundle to track payload destinations successfully moved
  during the loop and remove those staged files when a later diskCheck or
  moveItem operation throws, before rethrowing the original error. Keep
  cleanup limited to payloads created by this invocation so the stageOne
  fallback can reuse the payload names without masking the original failure.


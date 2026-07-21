# CodeRabbit AI prompts

Per-finding AI prompts saved by the CLI with the review in
FINDINGS.md, captured by a second `coderabbit review --show-prompts`
invocation (EVA-31). RECORDED as reconciliation aid \u2014 understanding
why CodeRabbit flagged a finding, tuning `--config` instructions \u2014
and NEVER executed directly (the autofix rule).

Replaying 7 AI prompts from your last review on CED-14-multiple-galleries.

────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/UI/SettingsView.swift:8App/MobileSeal/UI/SettingsView.swift:8-33]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/UI/SettingsView.swift around lines 8 - 33, Persist the
  current galleryName whenever SettingsView is dismissed interactively, not
  only through TextField.onSubmit or the Done action. Update the sheet
  dismissal handling around SettingsView’s presentation lifecycle to call
  store.setGalleryName(galleryName) before dismissal, while preserving the
  existing submit and Done behavior.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/MobileSeal.xcodeproj/project.pbxproj:105MobileSeal.xcodeproj/project.pbxproj:105]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @MobileSeal.xcodeproj/project.pbxproj at line 105, Update the
  PBXFileReference entry identified by CED-14-multiple-galleries so its path
  points to goals/CED-14-multiple-galleries instead of the repository root,
  while preserving its folder type, name, and source tree settings.


────────────────────────────────────────────────────────────────────────
  minor [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/Support/GalleryLabelStore.swift:161App/MobileSeal/Support/GalleryLabelStore.swift:161-174]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/Support/GalleryLabelStore.swift around lines 161 - 174,
  Update setLabel(_:for:) so clearing an empty label propagates genuine
  FileManager removal errors while treating only a missing file as
  successful. Preserve the early return when the record is absent, and
  ensure stale ciphertext cannot remain silently after a failed removal.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSealUITests/MultiGalleryUITests.swift:135App/MobileSealUITests/MultiGalleryUITests.swift:135-150]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSealUITests/MultiGalleryUITests.swift around lines 135 -
  150, The test flow around setCover and the gallery list only verifies the
  “Beta Vault” label, not the selected cover. Add a stable accessibility
  identifier to the rendered cover, then assert that element exists after
  tapMoreMenuItem(label: "Switch Gallery") and the locked list appears.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/goals/CED-14-multiple-galleries/GOAL.md:107goals/CED-14-multiple-galleries/GOAL.md:107-108]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @goals/CED-14-multiple-galleries/GOAL.md around lines 107 - 108, Update
  the E2E gate claim in the goal documentation so it no longer attributes
  label custody verification to MultiGalleryUITests, which does not scan
  gallery-format files. Move the assertion to the unit/adversarial gate, or
  add explicit gallery-format verification to MultiGalleryUITests before
  retaining the E2E claim.


────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/GallerySwitchboard.swift:243App/MobileSeal/GallerySwitchboard.swift:243-287]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/GallerySwitchboard.swift around lines 243 - 287, Update
  performCreateGallery so it preserves the previously selected gallery and
  route before teardown/deselection, then restores that selection and
  publishes the corresponding .gallery route when coordinator.createGallery
  returns nil. Keep the existing failure handling for the no-selection case
  and leave successful creation behavior unchanged.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/GallerySwitchboard.swift:203App/MobileSeal/GallerySwitchboard.swift:203-207]8;;

  ▶ Prompt for AI agent
  Verify each finding against current code. Fix only still-valid issues,
  skip the rest with a brief reason, keep changes minimal, and validate.

  In @App/MobileSeal/GallerySwitchboard.swift around lines 203 - 207, Update
  performSelect so a missing record ID follows the same recovery behavior as
  performSwitchTo: call performBackToList() before returning. Preserve
  selectRecord(record) for IDs found in snapshot.records.


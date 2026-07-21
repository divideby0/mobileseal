# CodeRabbit findings

Connecting to CodeRabbit... 0s elapsed
Preparing review... 1s elapsed
────────────────────────────────────────
CodeRabbit Review

Diff      : committed changes only
Compare   : CED-14-multiple-galleries → main
Directory : CED-14-multiple-galleries
────────────────────────────────────────

(\(\
(• .•)  Get your code reviewed, or the bunny gets it.

Summarizing changes... 2s elapsed
Writing review comments... 38s elapsed
Writing review comments... 1m 00s elapsed - still working

────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/goals/CED-14-multiple-galleries/GOAL.md:107goals/CED-14-multiple-galleries/GOAL.md:107-108]8;;

  Align the E2E gate claim with its actual coverage.

  MultiGalleryUITests delegates label custody to unit tests and does not
  scan gallery-format files. Move this assertion to the unit/adversarial
  gate, or add the corresponding verification before claiming it as scripted
  E2E coverage.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSealUITests/MultiGalleryUITests.swift:135App/MobileSealUITests/MultiGalleryUITests.swift:135-150]8;;

  Assert that the selected cover renders on the locked list.

  The test taps “Set Cover” but only verifies the label afterward. A cover
  persistence/rendering regression would still pass this gate. Add a stable
  cover accessibility identifier and assert it after switching to the list.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/MobileSeal.xcodeproj/project.pbxproj:105MobileSeal.xcodeproj/project.pbxproj:105]8;;

  Point the CED-14 folder reference at the actual goal directory.

  path = . resolves this reference to the repository root, not
  goals/CED-14-multiple-galleries, so the Xcode navigator entry is
  misleading.


  Proposed fix

  - path = .;
  + path = goals/CED-14-multiple-galleries;

Writing review comments... 2m 39s elapsed - still working - 3 findings so far
Writing review comments... 3m 39s elapsed - still working - 3 findings so far
Writing review comments... 4m 39s elapsed - still working - 3 findings so far
Writing review comments... 5m 39s elapsed - still working - 3 findings so far
Writing review comments... 6m 39s elapsed - still working - 3 findings so far
Writing review comments... 7m 39s elapsed - still working - 3 findings so far
Writing review comments... 8m 39s elapsed - still working - 3 findings so far
Writing review comments... 9m 39s elapsed - still working - 3 findings so far

────────────────────────────────────────────────────────────────────────
  minor [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/Support/GalleryLabelStore.swift:161App/MobileSeal/Support/GalleryLabelStore.swift:161-174]8;;

  Swallowed error clearing an empty label leaves stale ciphertext.

  try? FileManager.default.removeItem(at: url) discards genuine removal
  failures (permissions, I/O). If removal fails, setLabel returns success
  while the old sealed record still exists on disk — the next label(for:)
  call reports the stale name/cover as if the clear had succeeded.


  🛡️ Proposed fix: only swallow "already absent"

       func setLabel(_ label: GalleryLabel, for galleryID: UUID) throws {
           let url = container.labelURL(galleryID: galleryID)
           if label.isEmpty {
  -            try? FileManager.default.removeItem(at: url)
  +            do {
  +                try FileManager.default.removeItem(at: url)
  +            } catch let error as CocoaError where error.code == .fileNoSuchFile {
  +                // Already absent — nothing to clear.
  +            }
               return
           }

Writing review comments... 10m 50s elapsed - still working - 4 findings so far
Writing review comments... 11m 50s elapsed - still working - 4 findings so far
Writing review comments... 12m 50s elapsed - still working - 4 findings so far

────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/UI/SettingsView.swift:8App/MobileSeal/UI/SettingsView.swift:8-33]8;;

  Gallery name edit is lost on swipe-to-dismiss.

  galleryName is only persisted via the TextField's onSubmit or the
  "Done" button (Line 116). Since this sheet has no
  .interactiveDismissDisabled, a user who types a name and swipes down to
  dismiss (without pressing return or tapping Done) silently loses the edit.





  🩹 Proposed fix

               }
               .navigationTitle("Settings")
               .navigationBarTitleDisplayMode(.inline)
  +            .onDisappear {
  +                store.setGalleryName(galleryName)
  +            }
               .toolbar {

  Also applies to: 109-124

Writing review comments... 14m 00s elapsed - still working - 5 findings so far
Writing review comments... 15m 00s elapsed - still working - 5 findings so far
Writing review comments... 16m 00s elapsed - still working - 5 findings so far
Writing review comments... 17m 00s elapsed - still working - 5 findings so far

────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/GallerySwitchboard.swift:203App/MobileSeal/GallerySwitchboard.swift:203-207]8;;

  Silent no-op when the target id isn't in the snapshot.

  performSwitchTo falls back to performBackToList() when the target
  record is missing (Lines 222-225), but performSelect just returns,
  leaving the route/UI unchanged with no feedback — e.g. a stale list entry
  whose directory vanished just does nothing on tap.






  🐛 Proposed fix

   private func performSelect(_ id: UUID) async {
       await teardownIfLive()  // defensive: the list should hold no DEK
  -    guard let record = snapshot.records.first(where: { $0.id == id }) else { return }
  +    guard let record = snapshot.records.first(where: { $0.id == id }) else {
  +        await performBackToList()
  +        return
  +    }
       await selectRecord(record)
   }


────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-14-multiple-galleries/App/MobileSeal/GallerySwitchboard.swift:243App/MobileSeal/GallerySwitchboard.swift:243-287]8;;

  Creation failure strands the user on .list instead of the prior gallery.

  When selected != nil (the single-gallery "New Gallery" flow, per the
  type doc at Lines 6-9), the code deselects and publishes .list before
  attempting coordinator.createGallery (Lines 245-249). If creation then
  fails, the guard at Line 250 returns early with the route already flipped
  to .list — contradicting both the inline comment "the route is
  unchanged" (Line 252-253) and AppRoute's documented policy that exactly
  one healthy gallery routes directly to .gallery (Lines 6-9). The user is
  left on the list surface with a single gallery, requiring an extra manual
  tap to get back into it.






  🐛 Proposed fix — restore prior selection on failure

   private func performCreateGallery(name: String?, password: String) async {
       await teardownIfLive()
  +    let previouslySelected = selected
       if selected != nil {
           await coordinator.deselect()
           selected = nil
           await publishRoute(.list)
       }
       guard let id = await coordinator.createGallery(password: password) else {
  -        // Failure already surfaced through the coordinator's sink;
  -        // the route is unchanged (setup screen or create sheet).
  +        // Failure already surfaced through the coordinator's sink;
  +        // restore whatever was previously active instead of
  +        // stranding the user on the list.
  +        if let previouslySelected {
  +            await selectRecord(previouslySelected)
  +        }
           return
       }


────────────────────────────────────────
Review complete
7 findings ✔

Major    1
Minor    6

32 files reviewed:
- App/MobileSeal/AppContainer.swift
- App/MobileSeal/GallerySwitchboard.swift
- App/MobileSeal/Grid/ThumbnailPipeline.swift
- App/MobileSeal/MobileSealApp.swift
- App/MobileSeal/Support/GalleryLabelStore.swift
- App/MobileSeal/Support/GalleryRegistry.swift
- App/MobileSeal/Support/LockPreferences.swift
- App/MobileSeal/UI/GalleryListView.swift
- App/MobileSeal/UI/GalleryView.swift
- App/MobileSeal/UI/SettingsView.swift
... and 22 more files
────────────────────────────────────────

Print all AI prompts: coderabbit review --show-prompts

REVIEW COMPLETE

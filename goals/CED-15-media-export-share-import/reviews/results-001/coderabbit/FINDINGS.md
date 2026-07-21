# CodeRabbit findings

Connecting to CodeRabbit... 0s elapsed
Preparing review... 1s elapsed
────────────────────────────────────────
CodeRabbit Review

Diff      : committed changes only
Compare   : CED-15-media-export-share-import → CED-14-multiple-galleries
Directory : CED-15-media-export-share-import
────────────────────────────────────────

(\(\
(• .•)  Because, faster merges = more features.

Summarizing changes... 1s elapsed
Summarizing changes... 1m 00s elapsed - still working
Summarizing changes... 2m 00s elapsed - still working
Summarizing changes... 3m 00s elapsed - still working
Summarizing changes... 4m 00s elapsed - still working
Summarizing changes... 5m 00s elapsed - still working
Summarizing changes... 6m 00s elapsed - still working
Summarizing changes... 7m 00s elapsed - still working
Summarizing changes... 8m 00s elapsed - still working
Summarizing changes... 9m 00s elapsed - still working
Writing review comments... 9m 26s elapsed - still working
Writing review comments... 10m 00s elapsed - still working
Writing review comments... 11m 00s elapsed - still working

────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/App/MobileSeal/Import/InboxMediaProvider.swift:23App/MobileSeal/Import/InboxMediaProvider.swift:23-41]8;;

  Validate the copied staging file before returning it.

  Lines 23-32 verify source, but Line 37 reads that path again. A
  replacement or write between those operations can cause unverified bytes
  to be staged and imported. Recheck dest’s length and BLAKE2b hash after
  copyItem succeeds, before appending the StagedPart.


  Proposed fix

               do {
                   try FileManager.default.copyItem(at: source, to: dest)
               } catch {
                   throw MediaProviderError.loadFailed(String(describing: error))
               }
  +            let stagedLength = try Self.length(of: dest, part: part)
  +            guard stagedLength == part.byteLength else {
  +                throw MediaProviderError.integrityMismatch(
  +                    "\(part.file): staged length \(stagedLength) ≠ manifest \(part.byteLength)")
  +            }
  +            let stagedHash = try MediaHashing.blake2b256Hex(of: dest)
  +            guard stagedHash == part.blake2b256 else {
  +                throw MediaProviderError.integrityMismatch(
  +                    "\(part.file): staged payload hash does not match manifest")
  +            }
               parts.append(StagedPart(url: dest, role: Self.role(of: part.role), uti: part.uti))


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/Tests/VaultCoreTests/MediaHashingTests.swift:24Tests/VaultCoreTests/MediaHashingTests.swift:24-28]8;;

  Make the test input exceed 1 MiB.

  `3
  Proposed fix

  -        for i in 0..<(3 << 18) {
  +        for i in 0..<((1 << 20) + 1) {

Writing review comments... 12m 43s elapsed - still working - 2 findings so far
Writing review comments... 13m 43s elapsed - still working - 2 findings so far
Writing review comments... 14m 43s elapsed - still working - 2 findings so far

────────────────────────────────────────────────────────────────────────
  major [Stability & Availability]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/App/MobileSeal/Export/ExportController.swift:80App/MobileSeal/Export/ExportController.swift:80-131]8;;

  Prevent a concurrent teardown from invalidating a staged batch
  stage() can still return a batch after tearDownExports() has canceled
  the same staging task and then swept the staging directory. Re-check
  teardown state after await task.value (for example, with a generation
  counter) before setting activeBatch, so a racing sweep can’t hand back a
  batch whose files are already gone.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-15-media-export-share-import/App/ShareInbox/InboxWriter.swift:188App/ShareInbox/InboxWriter.swift:188-232]8;;

  Clean up partially-moved payloads on live-photo staging failure.

  stageLivePhotoBundle moves each part directly to its final payloadName
  (Line 219). If the loop throws after moving index 0 but before index 1
  (e.g. diskCheck raises .diskFull on the paired video at Line 217),
  -0.payload is left in place. Back in stageOne, the try? at Line 98
  swallows that error and falls through to the movie/image branch, whose
  copyPayload targets the same -0.payload name — copyItem then fails
  with .copyFailed, so the intended graceful fallback never succeeds and
  the real error (.diskFull) is masked.

  Remove already-staged payloads before propagating so the fallback path
  starts clean:





  🐛 Proposed fix: roll back partial moves

           let fm = FileManager.default
           var payloads: [StagedPayload] = []
  -        for (index, source) in [(0, still), (1, video)] {
  -            let dest = store.inboxDir.appendingPathComponent(
  -                InboxManifest.payloadName(itemID: itemID, index: index))
  -            try diskCheck(for: source.0)
  -            do {
  -                try fm.moveItem(at: source.0, to: dest)
  -            } catch {
  -                throw InboxError.copyFailed(String(describing: error))
  -            }
  -            InboxStore.applyCustody(to: dest)
  -            payloads.append(
  -                StagedPayload(
  -                    url: dest, role: index == 0 ? .still : .pairedVideo, uti: source.1,
  -                    originalFilename: index == 0
  -                        ? (attachment.suggestedName ?? source.0.lastPathComponent)
  -                        : source.0.lastPathComponent))
  -        }
  +        do {
  +            for (index, source) in [(0, still), (1, video)] {
  +                let dest = store.inboxDir.appendingPathComponent(
  +                    InboxManifest.payloadName(itemID: itemID, index: index))
  +                try diskCheck(for: source.0)
  +                do {
  +                    try fm.moveItem(at: source.0, to: dest)
  +                } catch {
  +                    throw InboxError.copyFailed(String(describing: error))
  +                }
  +                InboxStore.applyCustody(to: dest)
  +                payloads.append(
  +                    StagedPayload(
  +                        url: dest, role: index == 0 ? .still : .pairedVideo, uti: source.1,
  +                        originalFilename: index == 0
  +                            ? (attachment.suggestedName ?? source.0.lastPathComponent)
  +                            : source.0.lastPathComponent))
  +            }
  +        } catch {
  +            for payload in payloads { try? fm.removeItem(at: payload.url) }
  +            throw error
  +        }
           return payloads

Writing review comments... 16m 08s elapsed - still working - 4 findings so far
Writing review comments... 17m 08s elapsed - still working - 4 findings so far
Writing review comments... 18m 08s elapsed - still working - 4 findings so far
Writing review comments... 19m 08s elapsed - still working - 4 findings so far

────────────────────────────────────────
Review complete
4 findings ✔

Major    2
Minor    2

34 files reviewed:
- App/MobileSeal/AppContainer.swift
- App/MobileSeal/Detail/MediaPagerViewController.swift
- App/MobileSeal/Export/ExportController.swift
- App/MobileSeal/Export/ExportShareFlow.swift
- App/MobileSeal/GallerySwitchboard.swift
- App/MobileSeal/Import/ImportEngine.swift
- App/MobileSeal/Import/InboxMediaProvider.swift
- App/MobileSeal/Import/MediaProvider.swift
- App/MobileSeal/MobileSeal.entitlements
- App/MobileSeal/MobileSealApp.swift
... and 24 more files
────────────────────────────────────────

Print all AI prompts: coderabbit review --show-prompts

REVIEW COMPLETE

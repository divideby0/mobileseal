Media Export & Share-Sheet Import — sixth executed leg, STACKED on
CED-14-multiple-galleries (touches the same grid/pager UI surfaces;
executes after CED-14 locks, before its merge).

Two halves, both cedric's design (2026-07-20):

OUT — Export via the full iOS share sheet: select items (pager single
or grid multi-select, same affordances as delete) → Share → AirDrop /
Save to Photos / Save to Files / any app. The vault's ONE deliberate
custody exit: generic pre-share warning (share sheet cannot reveal
destination; iCloud-transit risk named), byte-exact originals, Live
Photos export as their two files, large items may stage a temp file
handed to the OS (cleaned after, documented). Enables the manual
cross-gallery move (export → reimport → delete).

IN — MobileSeal as a share-sheet DESTINATION (Share Extension):
other apps share images/videos to MobileSeal. Extension NEVER unlocks
(120 MB extension memory limit; Argon2id research flagged extension
profiles) — it stages items into a protected app-group inbox
(Data Protection, no plaintext beyond the staging discipline) and the
main app prompts "Import N staged items into <current gallery>?" at
next unlock, reusing CED-11's staging→import path incl. cleanup and
crash sweep. Media types only this leg; arbitrary file types are fog
(need a non-media display story).

Constraints: stacked review wave diffs against CED-14 (stacked_on
frontmatter); app-group container + Keychain access-group additions
need xcodegen entitlement updates; zero-HITL gates on simulator
(inbox logic unit-tested; real share-from-Photos smoke joins the
HITL checklist).

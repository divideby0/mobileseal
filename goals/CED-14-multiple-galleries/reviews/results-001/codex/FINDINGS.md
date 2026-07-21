The change establishes the intended multi-gallery routing, serialized switch authority, per-gallery preferences, and encrypted device-local labels, but it is not ready to merge because two recovery paths can silently discard the only good metadata available: discovery hides directories whose `gallery.meta` is missing, and the legacy calibration migration deletes its source without validating the destination. `git diff --check` passed; project-native tests could not start in this restricted runner because SwiftPM/Xcode failed while initializing caches/sandbox services outside the writable roots, so that environmental failure is not counted as a product finding.

| # | Severity | Location | Finding |
|---|---|---|---|
| 1 | major | `App/MobileSeal/AppContainer.swift:145-153` | Gallery discovery filters out directories with a missing `gallery.meta`, so the registry cannot emit its promised unreadable-gallery error tile and may route an existing user to setup as though no gallery exists. |
| 2 | major | `App/MobileSeal/Support/GalleryRegistry.swift:220-230` | The supposedly crash-safe calibration migration treats any existing destination as valid and deletes the legacy source without performing the documented verification. |

## 1. Missing metadata makes a gallery disappear

Evidence: `App/MobileSeal/AppContainer.swift:145-153` enumerates `galleries/` and then retains only entries for which `gallery.meta` already exists. `App/MobileSeal/Support/GalleryRegistry.swift:75-90` can create `.unreadableMeta` failures only for URLs returned by that pre-filtered function. Consequently, deleting or losing `gallery.meta` from the sole gallery produces an empty `records` array and an empty `failures` array; `App/MobileSeal/GallerySwitchboard.swift:194-199` then publishes `.setup` rather than the required error-list route. The same silent-empty result occurs when `contentsOfDirectory` itself fails because the error is collapsed to `[]`.

This matters because the goal explicitly requires discovery failures to surface as error tiles rather than data loss. The encrypted chunks and manifests can still be present, but the UI tells the user there is no gallery and offers creation, hiding the damaged gallery and its recovery signal.

Suggested fix: enumerate actual directory entries under `galleries/` without requiring `gallery.meta` first, pass each directory to `readStructuralMeta`, and convert a missing meta file into `.unreadableMeta`. Represent a root-enumeration failure explicitly instead of returning an indistinguishable empty scan. Add tests for a directory with no `gallery.meta` and for an enumeration error, including the resulting bootstrap route.

## 2. Calibration migration can delete the last valid record

Evidence: `App/MobileSeal/Support/GalleryRegistry.swift:220-230` describes a “copy → verify → remove source” sequence, but the implementation only calls `copyItem`, skips the copy whenever the destination exists, and unconditionally removes the legacy file. There is no decode, byte comparison, or other validation of the destination. A crash or I/O interruption that leaves a partial destination therefore causes the next launch to take the `target exists` branch and delete the intact legacy calibration record. The injected failpoint at line 229 only models a crash after `copyItem` has returned successfully, so the tests do not cover this window.

This matters because the goal requires the existing gallery's calibration state to migrate atomically and idempotently. In this failure mode the vault remains discoverable, but its only valid calibration record is irreversibly lost, violating the zero-friction migration and preservation gate.

Suggested fix: first decode and validate the legacy record, write it to a temporary file in the destination directory, atomically rename it into place, then read back and validate (or exactly compare) the destination before removing the source. If a destination already exists but is invalid, replace it from the still-valid legacy source rather than deleting the source. Add a crash test with a pre-existing truncated/corrupt target and a valid legacy record.

REVIEW COMPLETE

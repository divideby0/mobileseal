iOS Vault App Shell — second leg of the private-photo-vault wayfinder
map, the first UI leg, drafted immediately after CED-10 (VaultCore
crypto core) merged to main at dc680f6.

Map ticket (from CED-10's locked wayfinder/MAP.md): Xcode app target:
import from Photos, app-generated encrypted thumbnails, grid + detail
UICollectionView-in-SwiftUI, lock/unlock UX with backgrounding
redaction. Blocked by: Vault Core Crypto & CAS — now resolved.

Carried into this leg from CED-10's RESULT.md follow-ups:

- Device Argon2id benchmark: assert the 0.5-1s unlock envelope on a
  real iPhone (macOS M4 Pro measured 0.324s at MODERATE); add the
  adaptive calibration step the research report recommends.
- Metadata custody decision: if plaintext EXIF/names enter the
  encrypted metadata blob for grid display, revisit holding decrypted
  blobs in SecureBytes (today: ordinary heap, access-revoked on lock).
- .coderabbit.yaml with goals/** review path filters as the FIRST
  commit (could not be added mid-CED-10 without perturbing a blind
  wave).
- Spec §11 hardening items that touch this surface: app-switcher
  snapshot redaction on scenePhase change, lock/zero on backgrounding
  (VaultCore lock() and drain semantics exist; wire them to the app
  lifecycle).

Import-fidelity fog to sharpen during grilling: Live Photos, HEIC/
ProRAW, bursts, EXIF privacy handling. Standing decisions: paid Apple
Developer account signing (session-001 Q5); device floor = latest
current OS on in-use devices; thumbnails app-generated and encrypted,
never system-generated (intake spec §6/§10).

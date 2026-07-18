---
status: draft
created: 2026-07-18T16:41:18-05:00
author: cedric
---

# Build Encrypted Multi-Gallery Photo Vault

## Problem

There is no private, zero-knowledge alternative to Apple Photos that
combines a Photos-equivalent browsing/playback UX with per-gallery
password encryption, offline-first multi-device sync, and optional
sharing. Cloud photo services see plaintext; existing vault apps
compromise on UX or on cryptographic posture. This goal builds a
personal-use (sideloaded) native iOS/iPadOS/visionOS app that closes
that gap.

The full handoff spec (v0.1) arrived as the intake and is preserved
verbatim at `references/intake.md` — it defines the architecture,
cryptographic design, schemas, and a 10-phase build plan. Everything
below derives from it; agent-inferred additions are marked as such.

## Scope

Per the intake spec (§13 build phases), the work spans:

1. **Core vault** — libsodium envelope encryption (Argon2id KEK →
   per-gallery DEK), 4 MiB-chunked content-addressed store,
   grid + detail view (UICollectionView wrapped in SwiftUI).
2. **Media playback** — swipe/zoom polish, streaming decrypt for
   video/audio via `AVAssetResourceLoaderDelegate` (per-chunk
   XChaCha20-Poly1305, random access — no plaintext temp files).
3. **Multiple galleries** — per-gallery DEK/password, switcher UI.
4. **Manifest/CRDT + device identity** — Ed25519/X25519 device keys,
   signed AddEntry/Tombstone set-union merge, trust-on-first-use.
5. **Local sync** — Multipeer/Bonjour hash-diff reconciliation.
6. **Supabase backend** — phone-OTP/Google auth, Postgres schema
   (galleries, members, invites, device keys), storage RLS.
7. **Cloud sync & sharing** — password path + sealed-box path,
   invite-by-phone/email.
8. **iPad adaptation**, 9. **visionOS port**, 10. **Security
   hardening pass** (spec §11 checklist).

**Sizing (agent-inferred): XXL (13) — well beyond one execution
session.** This draft is a strong wayfinder-map candidate; expected
outcome of refinement is a charted map whose first goal is
phase-1-sized (M–L), not a single monolithic goal.

## Green gates

Provisional — to be sharpened during grilling (gates below assume this
goal is re-scoped to the first executable slice; a wayfinder map would
restate them per ticket):

1. Encryption round-trip proven by tests: import → chunk → encrypt →
   decrypt → byte-identical export; AEAD tamper detection verified.
2. No plaintext ever written to disk outside an unlocked session
   (auditable by test or instrumentation).
3. App builds and runs on iOS Simulator; grid browsing of an
   encrypted gallery works end-to-end.
4. Blind multi-tool review wave completed and reconciled.

## References

- `references/intake.md` — the complete v0.1 technical spec
  (byte-for-byte intake; §5 crypto design, §7 Supabase schema/RLS,
  §9 CRDT model, §11 hardening checklist, §14 open decisions).

## Open questions (for grilling)

From the spec's own `[DECISION NEEDED]` markers (§14):

1. Argon2id cost params — `MODERATE/MODERATE` default; benchmark
   target hardware (what is the oldest supported device?).
2. Chunk size — 4 MiB default vs. smaller for video-scrub granularity.
3. Chunk addressing — ciphertext-hash (default, no dedup) vs.
   gallery-scoped convergent (dedup, scoped confirmation-attack risk).
4. DEK epoch rotation — v1 or deferred (spec recommends defer,
   reserve `epoch` schema field now).
5. Device trust bootstrap — trust-on-first-use (spec's pick) vs.
   explicit device approval.
6. Storage backend — Supabase Storage direct vs. `BlobStore`
   abstraction for multi-cloud.
7. Self-hosted vs. hosted Supabase.

Agent-added (not in spec §14):

8. Is this one goal or a wayfinder map? (Recommendation: map.)
9. Deployment/signing story for sideloading across iPhone/iPad/Vision
   Pro (free vs. paid dev account — 7-day vs. 1-year profiles; affects
   how annoying "personal use" actually is).
10. Minimum OS versions / device floor (drives SwiftData availability,
    Argon2id tuning, visionOS SDK choices).
11. What does v1 "usable daily" mean — which phase marks the point
    the app replaces whatever currently holds these photos?
12. Test strategy for crypto + sync (property tests? two-simulator
    Multipeer harness? Supabase local stack?).

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- Xcode project does not exist yet — this repo currently holds only
  evie-agent scaffolding; the first executable goal creates the app
  project (name: mobileseal — bundle id/team TBD in grilling).
- Supabase credentials/instance: none provisioned yet (open question
  7); phases 1–5 have no backend dependency.
- Crypto dependency: Swift-Sodium via SPM (spec §5.1 — sole crypto
  dependency; do not mix in CryptoKit or OpenPGP formats, do not use
  secretstream for file bodies).

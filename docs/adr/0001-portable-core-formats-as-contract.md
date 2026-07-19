# ADR 0001 — Portable core, formats as the cross-platform contract

- Status: accepted
- Date: 2026-07-19
- Context: CED-10 (VaultCore encryption and chunk store)

## Decision

The vault's cryptographic core is a **UIKit/SwiftData-free Swift
package (`VaultCore`)**, and the **on-disk formats — not the Swift
API — are the cross-platform contract**, specified normatively in
`docs/formats.md` and enforced by known-answer fixtures that an
independent implementation can verify against.

## Context

The Private Photo Vault spans iOS/iPadOS/visionOS apps today and a
macOS/Linux CLI peer later (wayfinder map). Every downstream leg —
app shell, streaming playback, CRDT sync, cloud backup — layers over
the same primitives: envelope encryption, chunked content-addressed
storage, and crash-consistent commits.

Two contract choices existed:

1. **API as contract** — ship VaultCore everywhere Swift runs, treat
   its types as the interface, let the bytes be an implementation
   detail.
2. **Formats as contract** — freeze the bytes (magics, versions,
   AADs, bounds, commit protocol) in a normative document; VaultCore
   is the _reference implementation_, replaceable per platform.

## Consequences

Choosing (2):

- A future CLI peer (or a Rust/Go reimplementation, or a recovery
  tool written after this codebase is gone) needs `docs/formats.md`
  and libsodium — nothing else. `FormatConformanceTests` proves this
  by decoding the committed fixture vault with only documented
  constants.
- Format changes are versioned, deliberate events (magic + version
  fields on every object), never silent side effects of refactoring.
- The Swift API can evolve freely (e.g. the drain-on-lock custody
  redesign from the Codex review) without breaking peers.
- Cost: dual maintenance — every behavior change that touches bytes
  must land in the document, and the fixture must be regenerated,
  in the same change.

## Notes

- The local inventory (format-version 0) is explicitly a
  this-leg-only artifact; the Manifest-CRDT leg supersedes it with
  signed entries, detectable via the version field.
- Swift-Sodium (libsodium) is the sole crypto dependency (spec §5.1);
  CryptoKit and secretstream designs were rejected upstream (no
  Argon2id; chained constructions defeat random access).

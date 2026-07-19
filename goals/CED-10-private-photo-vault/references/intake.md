# Private Photo Vault — Technical Specification (v0.1)

## 1. Overview

A native iOS / iPadOS / visionOS app that behaves like Apple Photos (grid
browsing, smooth swipe-to-advance, pinch-zoom, inline video/audio playback)
but stores content in one or more **password-protected galleries**, each
independently encrypted. Galleries can optionally be shared with other
people, synced across the owner's own devices, and backed up/recovered via
cloud object storage. This is a personal-use build (sideloaded, not
App Store distributed), which relaxes some constraints noted inline below.

This document is the handoff spec for a Claude Code build session. It
captures the architecture, cryptographic design, schemas, and phased build
plan. Sections marked **\[DECISION NEEDED]** are places where the spec picks
a reasonable default but the human should confirm before/while building.

---

## 2. Goals

- Photos-app-equivalent UX for viewing/browsing photos, videos, and audio.
- Multiple galleries, each with its own password.
- Files encrypted at rest at all times except while their gallery is
  unlocked in an active session.
- Sync across the owner's own devices (iPhone/iPad/Vision Pro), including
  local-network sync with no cloud dependency.
- Optional sharing of an entire gallery with other people, who can also
  **add** content but not delete others' content.
- Cloud backup/recovery via object storage, provider-agnostic where
  practical.
- Zero-knowledge posture: no backend or storage provider ever sees
  plaintext content, filenames, or passwords.

## 3. Non-Goals (v1)

- App Store distribution / review compliance.
- Airtight revocation of already-synced local content (not achievable in
  any offline-first design — see §5.6).
- Real-time collaborative editing/comments.
- Cross-account key recovery beyond "forgot the gallery password ⇒ that
  gallery's content is unrecoverable" (acceptable for personal use).

---

## 4. Architecture Summary

```
┌─────────────────────────────┐        ┌───────────────────────────┐
│  iOS / iPadOS / visionOS app │        │        Supabase           │
│                              │        │  ┌──────────────────────┐ │
│  ┌────────────────────────┐  │  HTTPS │  │ Auth (phone OTP /     │ │
│  │ UIKit media viewer      │  │◄──────►│  │ Google OAuth)        │ │
│  │ (grid, swipe, zoom,     │  │        │  └──────────────────────┘ │
│  │  AVPlayer w/ custom     │  │        │  ┌──────────────────────┐ │
│  │  resource loader)        │  │        │  │ Postgres: galleries, │ │
│  └────────────────────────┘  │        │  │ members, invites,    │ │
│  ┌────────────────────────┐  │        │  │ device keys (RLS)    │ │
│  │ Local encrypted CAS     │  │        │  └──────────────────────┘ │
│  │ store (chunks, manifest,│  │        │  ┌──────────────────────┐ │
│  │ trust list) — SwiftData │  │        │  │ Storage (S3-compat), │ │
│  │ index + files on disk   │  │        │  │ RLS-gated per object │ │
│  └────────────────────────┘  │        │  └──────────────────────┘ │
│  ┌────────────────────────┐  │        └───────────────────────────┘
│  │ Crypto layer            │  │
│  │ (libsodium via          │  │        ┌───────────────────────────┐
│  │ Swift-Sodium)           │  │◄──────►│ Peer devices (Multipeer/  │
│  └────────────────────────┘  │  local  │ Bonjour, no internet)     │
└─────────────────────────────┘  Wi-Fi   └───────────────────────────┘
```

Two identity layers exist side by side and must stay decoupled:

- **Account identity** (phone number or Google account via Supabase Auth) —
  governs coarse authorization (can this account touch this gallery's
  objects) and enables invite-by-phone-number/email.
- **Cryptographic identity** (an Ed25519 signing keypair + X25519
  encryption keypair generated per device) — governs authorship of
  additions/tombstones and enables password-free sealed-box sharing.

---

## 5. Cryptography

### 5.1 Primitives & Libraries

Use **Swift-Sodium** (libsodium wrapper) as the sole crypto dependency
rather than mixing CryptoKit with a separate Argon2 package — CryptoKit has
no Argon2id, and libsodium supplies everything needed in one place:

| Purpose                       | Primitive                                                 |
| ----------------------------- | --------------------------------------------------------- |
| Password → key derivation     | Argon2id (`crypto_pwhash`)                                |
| Per-chunk file encryption     | XChaCha20-Poly1305 (`crypto_aead_xchacha20poly1305_ietf`) |
| DEK wrapping (password-based) | XChaCha20-Poly1305 (`crypto_secretbox` equivalent)        |
| DEK wrapping (per-recipient)  | Sealed box (`crypto_box_seal`, X25519)                    |
| Device identity / signing     | Ed25519 (`crypto_sign`)                                   |
| Content hashing               | BLAKE2b (`crypto_generichash`)                            |

**Do not** use OpenPGP/GPG-format encryption (rejected earlier in design
discussion — legacy container format, weak Swift tooling, no benefit since
recipients are always this app or a small companion decryptor). Do not use
libsodium's `secretstream` for file bodies — it's a _chained_ construction
(each chunk depends on prior state), which is incompatible with
content-addressed, randomly-seekable chunks. Use independent per-chunk AEAD
instead (§5.3).

Argon2id parameters **\[DECISION NEEDED — tune on target hardware]**:
start with `OPSLIMIT_MODERATE` / `MEMLIMIT_MODERATE` (libsodium constants),
targeting roughly 0.5–1s unlock time on the oldest supported device; adjust
after benchmarking on real hardware.

### 5.2 Per-Gallery Envelope Encryption

- Each gallery generates one random 256-bit **DEK** at creation.
- The DEK is wrapped by a **KEK** = `Argon2id(password, per-gallery salt)`.
- Store: `wrapped_dek`, `salt`, `argon2_params` — small, unencrypted-but-
  meaningless-without-password metadata blob per gallery.
- Changing a gallery's password only re-wraps the DEK; no file
  re-encryption needed.

### 5.3 Chunking & Content Addressing

- Fixed chunk size: **4 MiB** \[DECISION NEEDED — tune; smaller improves
  video-scrub granularity at the cost of more objects/requests].
- Each chunk encrypted independently: `XChaCha20-Poly1305(DEK, nonce, chunk_plaintext)`.
  Nonce derived deterministically from `(fileID, chunkIndex)` — safe because
  each chunk uses a distinct nonce and the DEK is never reused across
  galleries.
- Chunk address = `BLAKE2b(ciphertext)` — this is the **default** addressing
  scheme (fully opaque to storage, no dedup).
  - Optional: gallery-scoped convergent addressing —
    `BLAKE2b(plaintext ‖ gallery_secret)` — enables dedup of identical
    content within a gallery at the cost of a well-known (and here,
    low-value) convergent-encryption confirmation attack, closed off by
    scoping the hash to a per-gallery secret rather than a global one.
    **\[DECISION NEEDED: ciphertext-hash (default) vs gallery-scoped
    convergent — pick before implementing GC/dedup logic.]**
- This independence is what enables: (a) random-access decryption for
  video scrubbing, (b) resumable/partial sync, (c) tamper detection per
  chunk on read (AEAD tag fails ⇒ discard and re-fetch from a peer).

### 5.4 Device Identity Keys

- On first launch on a device, generate one Ed25519 keypair (signing) and
  one X25519 keypair (sealed-box encryption target).
- Private keys wrapped at rest: `Argon2id(user passphrase, device salt)`
  wraps the private key material. Decrypted into memory only for the
  active session; not synced across devices (each device gets its own
  keypair — mirrors Signal's multi-device model, avoids needing a secure
  key-sync mechanism).
- Losing a device/passphrase is low-stakes by design: content access is
  gated by the gallery password (or sealed-box entries), not by this key.
  Recovery = sign back into the account, register a new device key.
- Public keys registered server-side in `user_devices` (§7.2) once the
  device has authenticated via Supabase Auth.

### 5.5 Sharing Unlock Paths

A gallery's access-control block supports **two coexisting unlock
mechanisms**, both just entries alongside each other:

1. **Password path (default, works for anyone):** `wrapped_dek` under
   `Argon2id(password)`, as in §5.2. Used for sharing with people without
   an account, or for out-of-band "here's a path and a password" sharing.
2. **Sealed-box path (for known accounts):** for each invited collaborator
   with a registered device public key, additionally store
   `crypto_box_seal(DEK, recipient_pubkey)`. Their device decrypts this with
   its own private key — no password ever exchanged. Multiple collaborators
   ⇒ multiple sealed-box entries, one per device public key.

### 5.6 Key Lifecycle & Revocation Semantics — read this before building anything access-control related

**Hard architectural fact:** once a device has decrypted gallery content
locally, no server-side action can retract it. This is inherent to
offline-first, client-side encryption, not a bug to fix later.

What _is_ achievable and should be implemented:

- **Stop future access**: removing a member from `gallery_members` (or
  deleting their sealed-box manifest entry) is checked by RLS/local
  validation on every future read _and write_ — a revoked device can't
  fetch new chunks/manifests, and can't push new content that syncs to
  others, even though it retains local decrypt capability for a fresh
  gallery-password-derived DEK it may have cached.
- **Stop future access to new content specifically**: optional DEK epoch
  rotation — rotate to a fresh DEK on membership change, re-wrap only for
  current members, leave prior content under the prior DEK. Cheap (re-wrap
  a 32-byte key, not re-encrypt content). **\[DECISION NEEDED: implement in
  v1, or defer — recommend deferring; add an `epoch` integer field to the
  schema now so it can be turned on later without a migration.]**

What is **not** achievable, and should not be promised in any UI copy:
undoing access to content already synced to a device before revocation.

---

## 6. Local Storage Layout

On-device, per gallery:

```
Vault/
  galleries/{gallery_id}/
    gallery.meta          -- wrapped_dek, salt, argon2_params, epoch
    chunks/{hash}          -- encrypted chunk blobs
    manifest/{hash}        -- encrypted manifest objects (see §9)
    HEAD                   -- current manifest hash (small mutable pointer)
    trustlist.enc          -- registered device pubkeys + roles (signed)
```

Index metadata (fast queries: date-sorted grid, search) lives in SwiftData,
itself storing only encrypted blobs/opaque references — never plaintext
filenames, dates-as-plaintext-if-sensitive, or system-visible thumbnails.
Generate and encrypt your own thumbnails; never let iOS's QuickLook/Photos
subsystems generate previews of vault content.

---

## 7. Backend (Supabase)

### 7.1 Auth

- Phone OTP and Google OAuth as first-class Supabase Auth providers (no
  custom JWT issuer needed — this is standard, built-in functionality).
- No anonymous auth needed now that real accounts are in play.

### 7.2 Postgres Schema

```sql
create table galleries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id) not null,
  created_at timestamptz default now()
);

create table gallery_members (
  gallery_id uuid references galleries(id) on delete cascade,
  user_id uuid references auth.users(id),
  role text check (role in ('member','owner')) default 'member',
  added_at timestamptz default now(),
  primary key (gallery_id, user_id)
);

create table gallery_invites (
  gallery_id uuid references galleries(id) on delete cascade,
  phone text,             -- E.164 format
  email text,
  role text default 'member',
  created_at timestamptz default now(),
  primary key (gallery_id, coalesce(phone, email))
);

create table user_devices (
  user_id uuid references auth.users(id),
  device_pubkey_ed25519 text not null,
  device_pubkey_x25519 text not null,
  created_at timestamptz default now(),
  primary key (user_id, device_pubkey_ed25519)
);
```

Trigger: on sign-in, promote any `gallery_invites` row matching the
authenticated user's verified phone/email into `gallery_members`.

### 7.3 Storage & RLS Policies

Path convention: `{gallery_id}/chunks/{hash}`,
`{gallery_id}/entries/{device_pubkey_hash}/...`,
`{gallery_id}/manifest/{hash}`.

```sql
create policy "gallery members read/write, owners delete"
on storage.objects for all
using (
  bucket_id = 'galleries'
  and exists (
    select 1 from gallery_members m
    where m.gallery_id = (storage.foldername(name))[1]::uuid
    and m.user_id = auth.uid()
    and (
      storage.allow_only_operation(array['object.get_authenticated','object.insert'])
      or m.role = 'owner'
    )
  )
);
```

No client role — including the owner's own devices — should have a
standing DELETE policy for chunk objects during normal operation; see
§11 (garbage collection is a separate, deliberate maintenance action).

### 7.4 Provisioning Flow

1. Owner's device creates a `galleries` row and a corresponding local
   `gallery.meta` (DEK, wrapped, salt).
2. No bucket-per-gallery needed — one shared Supabase Storage bucket,
   logically partitioned by the `{gallery_id}/...` path prefix and RLS.
3. Sharing = insert into `gallery_invites` (by phone/email) or, for
   already-registered users, directly into `gallery_members` +
   the sealed-box DEK entry (§5.5) once their device pubkey is known.

**\[DECISION NEEDED — storage backend choice]**: this section assumes
Supabase Storage directly (simplest; RLS enforces everything without a
separate broker). If true multi-cloud portability (raw AWS S3 / GCS /
R2 outside Supabase) turns out to matter later, see §12 for the
alternative `BlobStore` abstraction that keeps client sync code
unchanged either way.

---

## 8. Sync Protocol

Because storage is content-addressed, sync is always the same operation
regardless of transport: **diff the set of known hashes, transfer what's
missing.** No bespoke merge logic per transport.

### 8.1 Local-to-local

Multipeer Connectivity / Bonjour for same-Wi-Fi sync between the owner's
own devices — no internet dependency, no cloud round trip.

### 8.2 Local-to-cloud

Plain HTTPS GET/PUT against Supabase Storage (which exposes an
S3-compatible protocol), gated by the RLS policies in §7.3. At
personal-library scale (thousands, not millions, of objects), a simple
"exchange list of known hashes, diff" reconciliation is sufficient — no
need for Merkle trees or IBLT-style set reconciliation unless a gallery
becomes very large.

### 8.3 Reconciliation Algorithm (pseudocode)

```
local_hashes = enumerate(local chunk store)
remote_hashes = fetch manifest → list of referenced chunk hashes
to_upload   = local_hashes  - remote_hashes
to_download = remote_hashes - local_hashes
upload(to_upload); download(to_download)
merge_manifest(local_manifest, remote_manifest)  -- see §9, union of entries
```

---

## 9. Manifest / CRDT Model

Model the gallery's content list as a mergeable set, not a single
overwritten file:

```
AddEntry {
  content_hash: string
  chunk_list: [hash]
  encrypted_metadata: bytes   -- filename, date, EXIF
  author_device_pubkey: string
  signature: bytes            -- Ed25519 sign(entry fields)
}

Tombstone {
  target_entry_hash: string
  author_device_pubkey: string
  signature: bytes
}
```

Validity rule, checked locally by every client (not server-enforced,
purely a client-side trust rule using signatures): a tombstone is honored
only if its `author_device_pubkey` matches the original entry's author, or
matches a device belonging to a member with `role = 'owner'`.

Merging two devices' manifests is a plain set union — no ordering/clock
needed, since display order comes from each photo's own EXIF/date-taken
metadata (same as Photos), not from add-time.

Device trust bootstrapping: **\[DECISION — trust-on-first-use, chosen]**
any device belonging to an authenticated `gallery_members` account may
register its device pubkey and begin writing signed entries immediately;
no separate per-device approval step for v1.

---

## 10. Media Playback Engine

- Grid + detail view: `UICollectionView` with compositional layout,
  wrapped in SwiftUI, for Photos-equivalent scroll/zoom/transition feel —
  plain SwiftUI alone will not hit this bar.
- Video/audio: implement `AVAssetResourceLoaderDelegate` to intercept
  AVPlayer's read requests and serve decrypted chunks on demand — decrypt
  only the chunks needed for the current playback position, never the
  whole file up front, never to a plaintext temp file.
- Scrubbing: seeking maps to a byte range → maps to a chunk range →
  fetch/decrypt just those chunks (this is why independent per-chunk AEAD,
  not a chained stream cipher, was required in §5.3).
- Thumbnails: generated and encrypted by the app itself; never rely on
  system-generated previews.

---

## 11. Security Hardening Checklist

- \[ ] Redact app-switcher snapshot when a gallery is unlocked (swap to a
  placeholder view on `scenePhase` → `.background`/`.inactive`).
- \[ ] Zero/drop decrypted DEK and any plaintext buffers from memory on
  explicit lock and on backgrounding.
- \[ ] No plaintext temp files anywhere in the decrypt/playback path.
- \[ ] No client-facing code path can construct a delete-capable request
  for chunk objects during normal operation (§7.3); garbage collection
  of tombstoned content is a separate, deliberate, owner-triggered
  maintenance action using a higher-privileged path, not something
  any regular sync/write flow can reach.
- \[ ] Every chunk's AEAD tag is verified on read; failures are treated as
  "re-fetch from another peer/source," not silently accepted.
- \[ ] Rate-limit/backoff on repeated failed password attempts per gallery
  (local; no server round-trip needed since KEK derivation is local).

---

## 12. Storage-Agnosticism (optional path, if needed later)

If Supabase Storage specifically becomes limiting (self-hosting appetite,
cost, wanting to point at an arbitrary bucket), the client's sync layer
should sit behind one small interface so the rest of the app never knows
which backend is active:

```swift
protocol BlobStore {
    func uploadURL(for key: String, expiry: TimeInterval) -> URL
    func downloadURL(for key: String, expiry: TimeInterval) -> URL
    func exists(key: String) -> Bool
    // no client-facing delete — see §11
}
```

Any S3-compatible target (AWS S3, Cloudflare R2, Backblaze B2, MinIO, and
Supabase Storage itself via its S3-compatible protocol) can share one
concrete implementation of this interface. A raw (non-Supabase) backend
would need its own thin credential/permission story — see the earlier
discussion of owner-provisioned, delete-denied scoped IAM credentials — but
none of that touches client sync/CAS/manifest code either way.

---

## 13. Build Phases

1. **Core vault (single gallery)** — envelope encryption, chunked CAS on
   disk, basic grid + detail view, no sync yet.
2. **Media playback polish** — swipe navigation, zoom, `AVAssetResourceLoaderDelegate`-based streaming decrypt for video/audio.
3. **Multiple galleries** — per-gallery DEK/password, gallery switcher UI.
4. **Manifest/CRDT + device identity** — Ed25519/X25519 keygen, signed
   entries/tombstones, trust-on-first-use.
5. **Local sync** — Multipeer/Bonjour reconciliation between the owner's
   own devices.
6. **Supabase backend** — Auth (phone OTP/Google), schema from §7.2,
   RLS policies, provisioning flow.
7. **Cloud sync & sharing** — password-path and sealed-box-path unlock,
   invite-by-phone/email flow.
8. **iPad adaptation** — multi-column layouts, drag and drop.
9. **visionOS port** — separate design pass for spatial presentation, not
   a straight port of the iPad UI.
10. **Security hardening pass** — full checklist in §11.

---

## 14. Open Decisions Summary

| Decision                        | Default in this spec                  | Needs confirming?                          |
| ------------------------------- | ------------------------------------- | ------------------------------------------ |
| Argon2id cost params            | `MODERATE`/`MODERATE`, tune on device | Yes — benchmark                            |
| Chunk size                      | 4 MiB                                 | Yes — tune for scrub granularity           |
| Chunk addressing                | Ciphertext-hash (no dedup)            | Yes — vs. gallery-scoped convergent        |
| DEK epoch rotation              | Deferred, schema field reserved       | Yes — v1 or later                          |
| Device trust bootstrap          | Trust-on-first-use                    | Yes — vs. explicit approval                |
| Storage backend                 | Supabase Storage directly             | Yes — vs. BlobStore-abstracted multi-cloud |
| Self-hosted vs. hosted Supabase | Unspecified                           | Yes                                        |

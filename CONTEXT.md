# Mobileseal — domain glossary

The ubiquitous language for the Private Photo Vault. VaultCore (the
portable crypto core) is the bounded context these terms belong to;
`docs/formats.md` is the normative byte-level contract behind them.

## Terms

- **Gallery** — one independently-encrypted collection of media, with
  its own password, DEK, and on-disk directory (a gallery root whose
  path the embedder chooses; the `galleries/{id}/` container
  convention arrives with the App Shell leg). The unit of locking,
  sharing, and sync.
- **DEK (data-encryption key)** — the random 256-bit key that encrypts
  a gallery's chunks and inventory. Generated once at gallery
  creation; never stored raw.
- **KEK (key-encryption key)** — derived from the gallery password via
  Argon2id (`crypto_pwhash`, alg ARGON2ID13) over the per-gallery
  salt. Wraps the DEK; changing the password re-wraps only.
- **Epoch keyring** — the list of wrapped-DEK entries in
  `gallery.meta`, keyed by **epoch** (u32). Today exactly one entry
  (epoch 0); DEK rotation appends entries so old content stays
  readable under its original epoch without re-encryption.
- **Chunk** — a fixed-size (per-file, default 4 MiB) slice of a file's
  plaintext, independently AEAD-encrypted (XChaCha20-Poly1305, random
  24-byte nonce, positional AAD) and stored content-addressed under
  `chunks/{hash}`. The unit of random access, dedup, and future sync.
- **Chunk address** — BLAKE2b-256 of a stored object's full bytes
  (header + ciphertext); doubles as its CAS filename.
- **Dedup hash** — domain-separated BLAKE2b-256 of a file's whole
  plaintext; lives only inside the encrypted inventory. Dedup identity
  is media bytes: a re-import shares chunks but gets its own entry.
- **Entry** — one logical file in a gallery: file ID, chunk refs,
  lengths, and an opaque metadata blob, recorded in the inventory.
  Distinct entries may share chunks (dedup).
- **Device identity** — a device's Ed25519 signing keypair (CED-13),
  generated on first use, never synced. The public key IS the
  identity; custody is pluggable (`DeviceKeyStore`: Keychain
  device-bound in the app, passphrase-wrapped file at the CLI leg).
- **Trust list** — the signed, versioned device registry inside the
  manifest: public key, name, added-at, role (owner/member —
  recorded, not yet enforced). Append-only union in v1; genesis is
  self-signed by the creating device; new devices self-register on
  first write-capable unlock (**TOFU** — gallery-password possession
  is authorization in single-user semantics).
- **AddEntry** — a signed manifest entry: the v0 entry's full storage
  contract (file_id, aad_file_id, dedup hash, chunk geometry,
  metadata) plus author public key and the `migrated_from_v0` flag.
  Entry identity is `file_id`; signatures are domain-separated and
  gallery-bound.
- **Tombstone** — a signed deletion marker targeting an entry's
  `file_id` (plus the gallery-bound canonical digest when known).
  Applied only for trusted authors with a present, digest-matching
  target; otherwise held **inert** and reported (tombstone-before-add
  waits for its target). Suppresses the entry; chunks remain until
  the GC leg.
- **Manifest (v1)** — one complete sealed operation-set snapshot
  (trust list + signed entries + signed tombstones), content-
  addressed like the v0 inventory, with a LOCAL commit revision that
  is deliberately not part of the CRDT. Merge is set union: entries
  by file_id (migration duplicates collapse to the smallest canonical
  digest), tombstones by canonical bytes, trust by device-set union.
- **HEAD descriptor** — the sealed, signed half of the v1 HEAD:
  manifest address + device public key + per-device monotonic
  counter. Feeds the **rollback detector**: a KNOWN signer presenting
  an older-than-observed counter surfaces the "restored from an older
  backup?" acceptance flow, which re-baselines and RECORDS the
  acceptance in the device-local high-water store.
- **Delete tiers** (CED-13, Signal-style): _delete-for-myself_ = soft,
  device-local, restorable — the aggregate moves to **Recently
  Deleted** for 30 days; _delete-for-everyone_ = hard signed
  Tombstones for the whole aggregate (purge or expiry). Delete always
  targets the media AGGREGATE (original + linked thumbnail +
  Live-Photo video), never a bare entry.
- **Gallery registry** (CED-14) — the app-side discovery of galleries
  under the vault root: identity is the AUTHORITATIVE `gallery.meta`
  UUID (directory path is location only); a `registry.json` sidecar
  records created-dates only and is never authoritative for
  existence. Duplicate UUIDs (copied directories) and unreadable
  metas surface as error tiles, never silent loss.
- **Switchboard** (CED-14) — the process-wide actor that owns every
  select/unlock/lock/create transition as FIFO-serialized
  transactions, enforcing one-unlocked-at-a-time (exactly one live
  DEK): the old gallery's FULL teardown (participants swept, UI state
  cleared, custodian drained, key zeroed) completes before a target's
  KDF may begin. An APP policy layered above the per-path
  VaultProcessRegistry.
- **Device-local label** (CED-14) — a gallery's optional name + cover
  photo, THIS device only (like a contact nickname): AEAD-sealed
  under a dedicated `WhenUnlockedThisDeviceOnly` Keychain key with
  gallery-UUID AAD, ciphertext in Application Support (may ride
  backup; restoring without the key = graceful loss → relabel). Never
  written into any gallery-format file, never synced. Covers render
  pre-unlock by explicit opt-in and purge with the privacy shield.
- **Sealed plane** — the ciphertext-only API surface (`SealedVault`):
  enumerate/copy chunks, audit addresses, parse `gallery.meta`
  structurally — all without the DEK. What sync/backup tooling
  compiles against.
- **Unlocked plane** — everything reachable only through a successful
  `unlock`: the move-only `UnlockSession`, the `Gallery` actor
  (single writer), and revocable `ChunkReader`s. Locking drains
  readers and zeroes the DEK.
- **Snapshot** — an immutable, Sendable view of the inventory at one
  generation. Carries structural refs only; decrypted metadata comes
  from session-scoped accessors that die with the lock.
- **Inventory** — the encrypted local index (format-version 0) of all
  entries plus a monotonic **generation** counter; stored
  content-addressed under `manifest/{hash}` with `HEAD` pointing at
  the current one. A local artifact: the Manifest-CRDT leg replaces it
  with durable signed entries.
- **Sealed chunk provider** — the sealed-plane read seam
  (`SealedChunkProvider`): fetches stored chunk objects by chunk
  address, CAS-address-verified at the seam, no DEK involved. The
  local CAS is today's only real implementation; a future sync leg
  slots a remote fetch behind the same contract. Distinct from the
  import-side `ChunkSource` (move-only plaintext ingestion).
- **Streaming reader** — the plaintext-plane range reader
  (`StreamingReader`): serves arbitrary byte ranges of an entry by
  pulling sealed chunks through a provider and decrypting them into
  the residency-budgeted cache. AEAD + padding verification live
  here, never in a provider. Per-generation, like `ChunkReader`;
  revoked by lock.
- **Residency budget** — the cap on cache-owned decrypted chunk
  bytes (`ResidentChunkCache`): entries pin while borrowed, eviction
  zeroizes, misses coalesce, over-budget requests fail typed
  (`budgetExhausted`) rather than block; memory pressure halves the
  budget to a floor and recovery restores it. Response `Data`,
  decoded frames, and AVFoundation-internal buffers are documented
  residuals OUTSIDE the budget.
- **Request registry** — the loader delegate's ledger of accepted
  `AVAssetResourceLoadingRequest`s: each is served incrementally in
  ≤ one-chunk slices from its `currentOffset` and finished exactly
  once; cancellation unwinds the entry; the lock path fails every
  outstanding request before the custodian drain.
- **External-playback exemption** — the capture-shield truth table:
  AirPlay external playback is ALLOWED (owner decision), and while
  `isExternalPlaybackActive` the capture shield does not blank the
  player surface; screen recording/mirroring (scene-capture trait)
  blanks the LOCAL player whenever external playback is not active.

## Invariants worth remembering

- Plaintext and the DEK live only in `sodium_malloc`-guarded
  `SecureBytes`; plaintext leaves through borrowing closures only.
- Every mutation is WAL-staged; the commit point is the atomic HEAD
  swap. Crash at any step yields full pre- or post-state.
- Wrong password and a tampered keyring entry are deliberately
  indistinguishable (`dekUnwrapFailed`).
- Address audit (sealed) ≠ AEAD authenticity (unlocked). Sync tooling
  must never treat sealed-green as end-to-end integrity.

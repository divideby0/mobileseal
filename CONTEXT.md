# Mobileseal — domain glossary

The ubiquitous language for the Private Photo Vault. VaultCore (the
portable crypto core) is the bounded context these terms belong to;
`docs/formats.md` is the normative byte-level contract behind them.

## Terms

- **Gallery** — one independently-encrypted collection of media, with
  its own password, DEK, and on-disk directory
  (`galleries/{id}/`). The unit of locking, sharing, and sync.
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
- **Tombstone** — a signed deletion marker for an entry. NOT part of
  this leg — arrives with the Manifest-CRDT format that supersedes the
  local inventory.
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

## Invariants worth remembering

- Plaintext and the DEK live only in `sodium_malloc`-guarded
  `SecureBytes`; plaintext leaves through borrowing closures only.
- Every mutation is WAL-staged; the commit point is the atomic HEAD
  swap. Crash at any step yields full pre- or post-state.
- Wrong password and a tampered keyring entry are deliberately
  indistinguishable (`dekUnwrapFailed`).
- Address audit (sealed) ≠ AEAD authenticity (unlocked). Sync tooling
  must never treat sealed-green as end-to-end integrity.

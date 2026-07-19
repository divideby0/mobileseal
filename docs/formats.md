# Mobileseal vault on-disk formats — version 0

This document is the **cross-platform contract** for the Mobileseal
vault (CED-10, Codex B14). An independent implementation (the future
macOS/Linux CLI peer) must be able to read and write a vault using only
this document; the committed known-answer fixture under
`Tests/VaultCoreTests/Fixtures/kat-vault/` plus
`FormatConformanceTests` verify that property against the reference
implementation.

Everything here is **normative** unless marked otherwise. The local
inventory object is format-version 0 and is explicitly a LOCAL
artifact: the Manifest-CRDT leg supersedes it with the durable
signed-entry format, detectable via the version field.

## Conventions

- All multi-byte integers are **little-endian**, fixed-width, unsigned.
- All magic values are 8 bytes of ASCII.
- `‖` denotes byte concatenation.
- UUIDs are the 16 raw RFC 4122 bytes (network order, as printed).
- Hashes and addresses are **BLAKE2b-256**: libsodium
  `crypto_generichash` with 32-byte output, no key.
- Hex encodings are **lowercase**; parsers MUST reject uppercase.

## Algorithms (fixed for version 0)

| Purpose            | Primitive                                            | Sizes                |
| ------------------ | ---------------------------------------------------- | -------------------- |
| AEAD (all objects) | libsodium `crypto_aead_xchacha20poly1305_ietf`       | nonce 24 B, tag 16 B |
| KDF                | libsodium `crypto_pwhash`, alg `ALG_ARGON2ID13` (=2) | salt 16 B, key 32 B  |
| Hash / address     | libsodium `crypto_generichash` (BLAKE2b)             | digest 32 B          |

Passwords are **NFC-normalized UTF-8 bytes**. Implementations MUST
normalize before deriving the KEK, or identical passwords typed on
different platforms will fail to unlock.

## Directory layout

```
{gallery-root}/
  gallery.meta        envelope metadata + epoch keyring   (this doc §gallery.meta)
  chunks/{hex}        encrypted content chunks, CAS       (§Chunk object)
  manifest/{hex}      encrypted inventory objects, CAS    (§Inventory object)
  HEAD                pointer to current inventory        (§HEAD)
  wal/{txid}/         in-flight transaction staging       (§Commit protocol)
  unlock.throttle     NON-NORMATIVE local rate-limit sidecar (§Security notes)
```

CAS filenames are the lowercase-hex BLAKE2b-256 address of the **full
stored object bytes** (header **and** ciphertext). CAS insertion is
no-overwrite: an existing address is never rewritten.

## gallery.meta

| Offset | Len  | Field                | Constraint                     |
| ------ | ---- | -------------------- | ------------------------------ |
| 0      | 8    | magic                | `MSVMETA0`                     |
| 8      | 2    | format_version u16   | 0                              |
| 10     | 16   | gallery_uuid         |                                |
| 26     | 1    | kdf_alg u8           | 1 = Argon2id13                 |
| 27     | 4    | kdf_opslimit u32     | **bounds: 1 ≤ x ≤ 12**         |
| 31     | 8    | kdf_memlimit u64 (B) | **bounds: 16 MiB ≤ x ≤ 1 GiB** |
| 39     | 16   | kdf_salt             |                                |
| 55     | 2    | keyring_count u16    | **= 1 in v0** (see below)      |
| 57     | 78·n | keyring entries      | see below                      |

Keyring entry (78 bytes):

| Rel. offset | Len | Field                  | Constraint                     |
| ----------- | --- | ---------------------- | ------------------------------ |
| 0           | 4   | epoch u32              |                                |
| 4           | 24  | wrap_nonce             | random                         |
| 28          | 2   | wrapped_dek_length u16 | = 48                           |
| 30          | 48  | wrapped_dek            | 32 B DEK ciphertext ‖ 16 B tag |

The file length MUST be exactly `57 + 78·keyring_count`; trailing bytes
are rejected.

KDF parameter bounds MUST be validated **before any allocation** — a
tampered `gallery.meta` must not be able to demand a 100 GiB Argon2id
pass (Codex B13). Recommended production parameters: opslimit 3,
memlimit 256 MiB (libsodium MODERATE; see
`research/_default/argon2id-tuning-on-modern-iphones.md`).

DEK unwrap: `KEK = crypto_pwhash(out_len=32, password_utf8_nfc, salt,
opslimit, memlimit, ALG_ARGON2ID13)`, then AEAD-open `wrapped_dek` with
key KEK, nonce `wrap_nonce`, and AAD:

```
"mobileseal.dekwrap.v0" ‖ 0x00 ‖ gallery_uuid ‖ epoch u32 ‖ format_version u16
```

The keyring LAYOUT is a list keyed by epoch (Codex B4) so DEK rotation
needs no byte-layout change: rotation appends an entry with a fresh
epoch, and every stored object names the epoch it was sealed under.
Format v0 nonetheless pins `keyring_count` to exactly 1 (epoch 0) and
parsers MUST reject other counts: this implementation has no
multi-epoch key custody yet, and accepting entries it cannot read
would surface rotated content as spurious `authenticationFailed` —
silent data loss dressed as corruption (wave-002 review). The rotation
leg raises the allowed count and, with it, the multi-epoch read rules
below become operative.

## Chunk object (`chunks/{hex}`)

| Offset | Len | Field              | Constraint           |
| ------ | --- | ------------------ | -------------------- |
| 0      | 8   | magic              | `MSVCHNK0`           |
| 8      | 2   | format_version u16 | 0                    |
| 10     | 24  | nonce              | **random per chunk** |
| 34     | …   | ciphertext         | padded_len + 16 tag  |

The nonce is random (192-bit), never derived — this deliberately
supersedes intake §5.3's deterministic `(fileID, chunkIndex)` scheme
(Codex B1: file-ID uniqueness across re-imports/retries/devices is
unprovable; XChaCha20's nonce size exists for exactly this).

Chunk AAD (Codex B3 — position binding):

```
"mobileseal.chunk.v0" ‖ 0x00 ‖ gallery_uuid ‖ aad_file_id ‖
chunk_index u64 ‖ epoch u32 ‖ format_version u16
```

`aad_file_id` is the file ID the chunk was **sealed** under (the first
importer); the inventory records it per entry so deduplicated entries
can decrypt shared chunks. A validly-tagged chunk therefore cannot be
substituted at another index, file, gallery, or epoch.

Decrypted (padded) plaintext length MUST be: ≥ 65 536, ≤ the owning
entry's `chunk_size`, and a multiple of 65 536. Parsers MUST check
this from the ciphertext length **before** decrypting.

### Chunking and padding

- `chunk_size` is a per-file property recorded in the inventory.
  Bounds: **64 KiB ≤ chunk_size ≤ 8 MiB, multiple of 65 536** (Codex
  A8). Default: 4 MiB.
- `chunk_count = max(1, ceil(unpadded_length / chunk_size))`.
- Chunks `0 … chunk_count-2` carry exactly `chunk_size` content bytes.
- The tail chunk carries the remainder, zero-padded up to the next
  multiple of the **padding boundary 65 536**, minimum one boundary.
- A zero-byte file is one fully-padded chunk (65 536 zero bytes) —
  never zero chunks, so empty files have no unique size fingerprint
  (grill Q12, Codex B10).
- On read, implementations MUST verify: the padded length matches the
  value computed from `unpadded_length` (which is AEAD-protected inside
  the inventory), and every pad byte is zero. Violations are integrity
  errors, not ignorable.

## Inventory object (`manifest/{hex}`)

| Offset | Len | Field              | Constraint    |
| ------ | --- | ------------------ | ------------- |
| 0      | 8   | magic              | `MSVINVN0`    |
| 8      | 2   | format_version u16 | 0             |
| 10     | 24  | nonce              | random        |
| 34     | …   | ciphertext         | body + 16 tag |

Inventory AAD:

```
"mobileseal.inventory.v0" ‖ 0x00 ‖ gallery_uuid ‖ epoch u32 ‖ format_version u16
```

where `epoch` is the current keyring epoch at sealing time (0 today).

**Epoch discovery:** the sealing epoch is intentionally NOT stored in
the cleartext header. In format v0 the keyring holds exactly one epoch
(0), so discovery is trivial. When rotation raises the allowed keyring
count, the binding rule becomes: attempt AEAD open under each keyring
epoch, highest first, until a tag verifies — the AAD binds the epoch,
so a successful open AUTHENTICATES which epoch sealed the object, and
the keyring bound keeps the work finite. Chunk objects never need
trial decryption: each inventory entry records its chunks' epoch.

Decrypted body:

| Field       | Type     | Constraint                            |
| ----------- | -------- | ------------------------------------- |
| generation  | u64      | +1 per commit; recovery picks the max |
| entry_count | u32      | ≤ 1 000 000                           |
| entries     | repeated | see below                             |

Entry (variable length, in order):

| Field           | Type / len | Constraint                                              |
| --------------- | ---------- | ------------------------------------------------------- |
| file_id         | 16 B UUID  | unique within the inventory                             |
| aad_file_id     | 16 B UUID  | = file_id for first import; original's for dedup        |
| epoch           | u32        | keyring epoch of the chunks' DEK                        |
| chunk_size      | u32        | §Chunking bounds                                        |
| unpadded_length | u64        | true file length, **≤ 2^48** bytes                      |
| dedup_hash      | 32 B       | BLAKE2b-256(`"mobileseal.dedup.v0" ‖ 0x00 ‖ plaintext`) |
| chunk_count     | u32        | MUST equal max(1, ceil(unpadded/chunk_size))            |
| chunk_addresses | 32 B each  | chunk_count entries                                     |
| metadata_length | u32        | ≤ 1 MiB                                                 |
| metadata        | bytes      | opaque to VaultCore                                     |

Trailing bytes after the last entry are rejected. The maximum stored
inventory object size is 256 MiB.

The dedup hash's domain prefix keeps it in a different domain from
object addresses (Codex A4); it lives ONLY inside this encrypted
object. Dedup identity is media bytes: a re-import creates a new entry
(fresh `file_id`) sharing the original's `chunk_addresses`,
`aad_file_id`, `epoch`, and `chunk_size`.

### File identity

`file_id` is a random UUID minted once per logical import. A retry
after a failed (uncommitted) transaction MAY reuse the same `file_id`
under a new txid; once a transaction containing a `file_id` has
committed, that ID is never minted again.

## HEAD

Exactly 42 bytes: `MSVHEAD0` ‖ format_version u16 (=0) ‖ 32-byte
address of the current inventory object.

## Commit protocol

All mutation is transactional (Codex B8). Steps, in order:

1. Create `wal/{txid}/chunks/` and `wal/{txid}/manifest/`
   (txid: any unique name; reference uses a random UUID).
2. Write each new chunk object to `wal/{txid}/chunks/{hex}`; fsync
   each file.
3. Write the new inventory object to `wal/{txid}/manifest/{hex}`;
   fsync.
4. Rename each staged chunk into `chunks/{hex}` (skip if the address
   already exists — CAS no-overwrite); fsync the `chunks/` directory.
5. Rename the staged inventory into `manifest/{hex}`; fsync the
   `manifest/` directory. (Object file before its parent directory.)
6. **COMMIT POINT**: write `HEAD.tmp` (fsync), atomically rename onto
   `HEAD`, fsync the gallery root directory.
7. Delete `wal/{txid}/` (best-effort; recovery also cleans it).

fsync ordering is normative: object file → its parent directory →
HEAD → HEAD's parent directory.

### Recovery

On opening a vault:

- Delete every `wal/{txid}/` directory (an uncommitted transaction's
  staging, or already-published leftovers) and any `HEAD.tmp`.
- If HEAD is missing, structurally invalid, or points to an absent
  object: fall back to the **highest-generation** inventory object in
  `manifest/` that decrypts and parses cleanly, and repair HEAD to it.
  If none exists, the vault is unrecoverable without re-sync
  (`noValidInventory`).
- If HEAD points at a present object whose AEAD **fails**: surface an
  integrity error. Deliberate tampering is NOT silently rolled back to
  an older inventory.
- Orphan chunk objects (present but unreferenced) are harmless; they
  are reported by deep verification and reclaimed by a future GC leg.

Rollback detection (an attacker restoring an older HEAD + inventory
pair, both cryptographically valid) is **out of scope for a lone local
vault** — there is no reference point to detect rollback against; the
signed-CRDT manifest leg owns that property.

## Verification tiers

- **Sealed (address) tier** — no DEK: every CAS object's bytes hash to
  its filename; HEAD parses and points at an existing object. Catches
  corruption and naming inconsistencies ONLY — an attacker who
  replaces blob and filename together defeats it.
- **Deep (AEAD) tier** — requires the DEK: every chunk of every entry
  decrypts with a valid tag under its positional AAD and passes
  padding/length validation. This is the end-to-end integrity check.

Implementations MUST verify the AEAD tag on every chunk read (§intake
§11); a tag failure is an integrity error, never silently accepted.

## Security notes (non-normative)

- **Secure memory**: the reference implementation keeps the DEK and
  all decrypted plaintext in `sodium_malloc` guarded allocations
  (canary + zero-on-free). `sodium_malloc` failure aborts unlock with
  a typed error. **`mlock` failure does NOT abort** (Codex Q7): iOS
  memory limits make mlock refusal routine; guarded allocation is
  still used, only page-locking is best-effort.
- **`unlock.throttle`** is a local, non-normative sidecar recording
  failed-unlock backoff state (magic `MSVTHRT0`, version u16,
  failure_count u32, last_failure_unix_ms u64). Peers MUST ignore and
  never sync it. It throttles interactive guessing only; an attacker
  with filesystem write access can delete it (and could equally
  brute-force offline).
- **Metadata custody trade** (wave-001): entries' opaque metadata
  blobs are parsed into ordinary heap for the session's lifetime.
  `lock()` revokes ACCESS to them (accessors fail closed) but does not
  wipe the arrays; content plaintext, by contrast, only ever lives in
  guarded memory. Apps storing sensitive metadata should encrypt the
  blob before handing it to VaultCore (the field is opaque by design).
- **Password normalization residual** (wave-001): NFC normalization
  allocates a transient Swift `String` in ordinary heap that is
  deallocated unwiped. VaultCore retains no password copy; callers
  needing to avoid the transient can pass pre-normalized bytes.
- **Drain force-zero is a deliberate bounded race** (wave-001): past
  the drain deadline the DEK is zeroed even if a straggling read is
  mid-decrypt. The straggler's AEAD tag check then fails and the read
  surfaces the typed lock error — a zeroed or partially-zeroed key
  cannot produce valid plaintext. Bounded blocking was chosen over
  unbounded waiting; the concurrent write to bytes libsodium is
  reading is accepted and documented rather than emergent.
- **Single-process assumption** (Codex A2): one process owns a gallery
  directory at a time. Concurrent multi-process access semantics are a
  CLI-leg question.
- The sealed plane exposes chunk COUNT and SIZES (padded); tail
  padding to 64 KiB coarsens exact-length leakage; decoy-chunk
  bucketing is deferred to the cloud-sync leg.

# Mobileseal vault on-disk formats — versions 0 and 1

This document is the **cross-platform contract** for the Mobileseal
vault (CED-10, Codex B14). An independent implementation (the future
macOS/Linux CLI peer) must be able to read and write a vault using only
this document; the committed known-answer fixtures under
`Tests/VaultCoreTests/Fixtures/` (`kat-vault/` — a pre-migration v0
vault — and `kat-vault-v1/` — a migrated vault with a tombstoned
aggregate) plus `FormatConformanceTests` /
`FormatConformanceV1Tests` verify that property against the reference
implementation.

Everything here is **normative** unless marked otherwise.

**Format v1** (CED-13) supersedes the v0 local inventory with the
**signed manifest**: per-device Ed25519 identities, signed
AddEntry/Tombstone/TrustList objects, a signed HEAD descriptor, and
set-union merge semantics. `gallery.meta`, chunk objects, chunking,
padding, the commit protocol, and the CAS layout are UNCHANGED from
v0 — v1 changes only what lives in `manifest/` and `HEAD`. A v0 vault
migrates in place (§Migration); the HEAD magic is the format marker.

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

## Inventory object (`manifest/{hex}`) — v0, superseded

> **Superseded in v1** by the Manifest object (§Format v1). A v0
> inventory is read exactly once more — as migration input. After
> migration the v0 object file may remain in the CAS unreferenced
> (reclaimed by the future GC leg); readers in the v1 world ignore it
> except during HEAD-loss recovery (§Recovery v1).

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

## Format v1 — the signed manifest (CED-13)

### Device identity

Every device holds one **Ed25519 signing keypair** (libsodium
`crypto_sign`, 32-byte public key, 64-byte secret key), generated on
first use and **never synced**. Custody is implementation-defined
behind a pluggable key store (the reference iOS app uses a
device-bound Keychain item; see §Security notes). Identity IS the
public key; names/roles are display metadata.

Authority semantics in v1 are **single-user / multi-device**: every
device in the trust list belongs to the vault owner, and possession of
the gallery password is authorization. Roles are RECORDED for future
use; multi-party authority (genesis attestation, escalation
resistance, revocation, owner recovery) is deferred to the sharing
legs, which will bump the format version.

### Signed-object common form

Every signed object is a **canonical byte encoding**: fixed field
order, little-endian fixed-width integers, length-prefixed bounded
blobs, canonical sort orders, duplicate rejection — exactly one byte
representation per logical value; parsers MUST reject alternates.

The detached Ed25519 signature covers:

```
domain ‖ sig_version u16 (=1) ‖ gallery_uuid(16) ‖ payload
```

where `domain` is the object kind's NUL-terminated ASCII domain
separator and `payload` is the object's full canonical payload
(every semantic field, epoch included where present). A signature is
therefore bound to object kind, format version, and gallery — no
cross-gallery or cross-kind replay. Stored form is always
`payload ‖ signature(64)`.

| Object kind     | Signing domain                   |
| --------------- | -------------------------------- |
| AddEntry        | `mobileseal.sig.add-entry.v1\0`  |
| Tombstone       | `mobileseal.sig.tombstone.v1\0`  |
| TrustList       | `mobileseal.sig.trust-list.v1\0` |
| HEAD descriptor | `mobileseal.sig.head.v1\0`       |

**Verification order is normative**: AEAD-decrypt the container →
canonical parse (structural bounds, orders, duplicates) → verify
signatures → trust checks. Each layer fails with its own typed error;
signature failure MUST be distinguishable from AEAD failure.

### AddEntry

Payload (in order):

| Field            | Type / len | Constraint                             |
| ---------------- | ---------- | -------------------------------------- |
| file_id          | 16 B UUID  | entry identity, unique within manifest |
| aad_file_id      | 16 B UUID  | v0 rule verbatim (dedup AAD context)   |
| epoch            | u32        | keyring epoch of the chunks' DEK       |
| chunk_size       | u32        | §Chunking bounds                       |
| unpadded_length  | u64        | ≤ 2^48                                 |
| dedup_hash       | 32 B       | v0 rule verbatim                       |
| chunk_count      | u32        | = max(1, ceil(unpadded/chunk_size))    |
| chunk_addresses  | 32 B each  | chunk_count entries                    |
| metadata_length  | u32        | ≤ 1 MiB                                |
| metadata         | bytes      | opaque to VaultCore                    |
| author_pubkey    | 32 B       | Ed25519 public key                     |
| migrated_from_v0 | u8         | 0 or 1 (others rejected)               |

An AddEntry is a **superset of the v0 inventory entry** — dedup-shared
chunks, thumbnail/Live-Photo links (inside the opaque metadata), and
readers keep working across migration. **Entry identity is
`file_id`.**

The **canonical entry digest** (tombstone targeting) is:

```
BLAKE2b-256("mobileseal.digest.add-entry.v1" ‖ 0x00 ‖ gallery_uuid ‖
            payload ‖ signature)
```

### Tombstone

Payload (in order): `target_file_id(16)` ‖ `has_target_digest u8
(0|1)` ‖ `[target_digest(32) iff 1]` ‖ `author_pubkey(32)`.

A tombstone **targets the durable `file_id`**, plus the canonical
digest of the targeted AddEntry when the author knew it. Application
rule (normative):

- the author MUST be in the trust list (in v1's single-user semantics
  every trusted device passes; the author-or-owner rule gains force
  with sharing), AND
- the target `file_id` MUST be present (a tombstone-before-add is
  held **inert** — retained, reported, applied when the target
  appears), AND
- when a digest is present it MUST match the target's canonical
  digest, EXCEPT when the target is `migrated_from_v0` — migration
  duplicates are one logical entry across re-signings, so a digest
  minted against one peer's re-signing applies to the surviving
  representative.

Any other case (unknown author, malformed/mismatched digest on a
non-migrated entry) leaves the tombstone **inert and reported**, never
an error. A suppressed entry's chunks remain in the CAS (space
reclaim is the GC leg's).

### TrustList

Payload (in order): `list_version u64` ‖ `device_count u32 (1…1024)` ‖
devices ‖ `signer_pubkey(32)`. Each device: `pubkey(32)` ‖
`role u8 (1=owner, 2=member)` ‖ `added_at_unix_ms u64` ‖
`name_len u16 (≤256)` ‖ `name (UTF-8)`. Devices MUST be sorted
strictly ascending by public key bytes (duplicates impossible).

The signer MUST itself be listed (self-signed trust root — **TOFU**,
deliberately: gallery-password possession is authorization in v1).
Genesis is minted at gallery creation/migration by the creating
device (`list_version` 1, owner role). New devices self-register at
their first write-capable unlock, folded into their next commit:
`list_version` + 1, member role, **append-only device-set union** —
v1 has no removal (revocation is a sharing-leg concern).

Merge of same-pubkey records is field-wise deterministic: min role
value (owner wins), min added_at, lexicographically smaller name.

### Manifest object (`manifest/{hex}`)

| Offset | Len | Field              | Constraint    |
| ------ | --- | ------------------ | ------------- |
| 0      | 8   | magic              | `MSVMANF1`    |
| 8      | 2   | format_version u16 | 1             |
| 10     | 24  | nonce              | random        |
| 34     | …   | ciphertext         | body + 16 tag |

AAD: `"mobileseal.manifest.v1" ‖ 0x00 ‖ gallery_uuid ‖ epoch u32 ‖
format_version u16` (sealing keyring epoch, 0 today; epoch discovery
as in v0). Maximum stored size 256 MiB.

Decrypted body (in order):

| Field           | Type     | Constraint                              |
| --------------- | -------- | --------------------------------------- |
| local_revision  | u64      | LOCAL commit revision — see below       |
| trust_list      | signed   | §TrustList (self-delimiting)            |
| entry_count     | u32      | ≤ 1 000 000                             |
| entries         | repeated | §AddEntry, sorted strictly ⬆ by file_id |
| tombstone_count | u32      | ≤ 1 000 000                             |
| tombstones      | repeated | §Tombstone, sorted strictly ⬆ by bytes  |

Trailing bytes are rejected. A manifest object is **one COMPLETE
operation-set snapshot** — the trust list is embedded (not referenced
by address) so the WAL commit's atomicity covers it and recovery
never faces a dangling trust reference.

**`local_revision` is the v0 generation counter's survivor**: +1 per
committed local mutation, feeding snapshot streams and recovery's
highest-revision rule. It is **NOT part of the CRDT** — never signed,
never merged, never compared across devices, and peers MUST ignore it
in any future exchange. Migration sets it to `v0 generation + 1` so
v0 and v1 objects share one recovery axis.

**Merge** (normative, for any two states of one gallery): entries
merge by set union keyed on `file_id`; when the same `file_id`
carries different signed bytes (possible ONLY via independent v0
migrations — `file_id`s are minted once), the representative with the
lexicographically **smallest canonical digest** survives, making
merge commutative, associative, and idempotent. Tombstones merge by
exact-canonical-bytes union. Trust lists merge as the device-set
union (above) with `list_version = max`; the committing device
re-signs the carrier.

### HEAD (v1)

Fixed 218 bytes:

| Offset | Len | Field              | Constraint                                             |
| ------ | --- | ------------------ | ------------------------------------------------------ |
| 0      | 8   | magic              | `MSVHEAD1`                                             |
| 8      | 2   | format_version u16 | 1                                                      |
| 10     | 32  | manifest_address   | plaintext (sealed plane resolves HEAD without the DEK) |
| 42     | 24  | nonce              | random                                                 |
| 66     | 152 | sealed descriptor  | 136 B plaintext + 16 B tag                             |

Descriptor AAD: `"mobileseal.head.v1" ‖ 0x00 ‖ gallery_uuid ‖
epoch u32 ‖ format_version u16`.

Descriptor plaintext: `manifest_address(32)` ‖ `device_pubkey(32)` ‖
`head_counter u64` ‖ `signature(64)` — the signature per the common
form under the HEAD domain. The inner (signed) manifest address MUST
equal the plaintext one; a mismatch is a signature-layer failure (a
spliced HEAD). The device public key and counter — the rollback
material — are never on disk in cleartext.

`head_counter` is **per-device monotonic**: each device signs
`counter + 1` relative to the highest counter it has itself written
(or recorded). Writing HEAD is part of the v0 commit protocol
unchanged; only the bytes differ.

### Migration (v0 → v1)

Triggered by unlocking a vault whose HEAD is v0. Idempotent state
machine, order normative:

1. Device key ensured (key store creation is idempotent).
2. Trust-list genesis staged (creating device, owner, version 1).
3. Manifest staged: every v0 entry re-signed by the migrating device
   with `migrated_from_v0 = 1`, all v0 fields verbatim;
   `local_revision = v0 generation + 1`; no tombstones.
4. ONE WAL commit (manifest object + v1 HEAD) — the v0 object is
   superseded exactly at the HEAD-swap commit point.
5. Rollback high-water mark initialized (device-local).

A crash before the commit point leaves the v0 world (re-running any
prefix is a no-op); after it, the v1 world. Two devices independently
migrating the same backed-up v0 vault converge under the migration
equivalence rule (§Manifest merge).

### Recovery (v1)

- HEAD (v1) → present object: open, verify (order above), verify the
  HEAD descriptor, check its signer is in the manifest's trust list,
  run the rollback detector.
- HEAD (v0) → present object: migration input (above).
- HEAD missing/corrupt/dangling: scan `manifest/` for the
  highest-local-revision valid object across BOTH formats (v1
  manifest revision / v0 inventory generation — one axis); ties
  prefer v1, then the lexicographically larger address. Repair HEAD:
  in the v1 world the repairing device signs a fresh descriptor with
  its own next counter (best-effort, like v0's repair).
- HEAD → present object that fails AEAD: typed integrity error;
  tampering is NOT silently rolled back (v0 rule, unchanged).

### Rollback detection (honestly scoped)

Each device keeps a **device-local high-water mark** per (gallery,
signer): the highest `head_counter` it has observed from that signer.
The store lives OUTSIDE the vault directory, beside the device
identity, excluded from backup — so it neither rolls back with a
restored vault nor follows the vault to a new device (where a fresh
device rightly starts with no marks). The detector fires ONLY when a
KNOWN signer presents a counter LOWER than its recorded mark; the
embedder surfaces a "restored from an older backup?" acceptance flow
whose acceptance re-baselines the mark **and records the acceptance**
durably.

What this does NOT detect (normative honesty): omission of individual
CRDT elements inside a manifest, replay of another trusted signer's
older HEAD on a device that never observed that signer, or a signer
minting a higher counter over older content. Stronger detection
(peer attestation) is the sync leg's.

### Device migration / restore

A vault restored to a new device (backup, transfer) arrives WITHOUT
the old device's key (Keychain `ThisDeviceOnly`) and without
device-local state. The new device enrolls as a NEW device via TOFU;
old entries remain valid under the old public key forever; no
recovery of the old identity is needed in single-user semantics.

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
  directory at a time. WITHIN a process, the reference implementation
  enforces one writer per gallery directory across all unlock
  sessions, serializes unlock attempts per gallery (so concurrent
  guesses cannot bypass the backoff), and revokes a session's
  capabilities when the session is dropped without an explicit lock
  (wave-003 review). Concurrent multi-process access semantics — an
  on-disk lock — are a CLI-leg question.
- The sealed plane exposes chunk COUNT and SIZES (padded); tail
  padding to 64 KiB coarsens exact-length leakage; decoy-chunk
  bucketing is deferred to the cloud-sync leg.
- **Device-key custody (v1, reference iOS app)**: the Ed25519 secret
  key is a Keychain generic-password item
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) — device-bound
  Keychain custody, NOT Secure-Enclave-resident (the SE cannot host
  libsodium Ed25519). `ThisDeviceOnly` keeps it out of every backup:
  a restored vault re-enrolls as a new device via TOFU. Exactly ONE
  audited code point (`KeychainDeviceKeyStore`) moves raw key bytes
  between the Keychain's `Data` and `SecureBytes`, zeroing the
  intermediary both directions; `DeviceIdentity` exposes no secret
  accessor (compile-fail-pinned). Residuals: the Security framework's
  own transient copies during `SecItem` calls, and — as with all v1
  signing — signature computation reads the key inside a bounded
  closure. Simulator tests assert the item's attributes and API
  behavior; device-bound/protection-class ENFORCEMENT is hardware
  behavior on the HITL validation checklist.
- **Device-local state locations (v1, reference iOS app)**: the
  rollback high-water store
  (`Application Support/DeviceLocal/rollback-state.json`) and the
  soft-delete ledger
  (`DeviceLocal/recently-deleted-{galleryUUID}.json`) live OUTSIDE
  the vault root with `isExcludedFromBackup` set — deliberately: a
  backed-up high-water mark would roll back with the vault it checks,
  and a migrated one would false-fire on the new device. Neither file
  is part of the cross-platform vault contract; they hold file IDs,
  counters, and dates — never keys or plaintext.
- **Soft delete is device-local in v1** ("delete for myself"): the
  ledger above hides aggregates locally; only purge/expiry writes
  CRDT tombstones. The per-user soft-delete merge algebra is designed
  at the sync leg.

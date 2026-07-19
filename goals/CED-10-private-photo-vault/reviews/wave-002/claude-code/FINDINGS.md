# Blind review — wave-002 / claude-code

## Verdict

This is a strong, unusually disciplined change. The format contract in
`docs/formats.md` is genuinely normative and is proved so by a
conformance test that decodes the committed fixture using only
transcribed constants; the corruption matrix, crash-consistency
fault injection, drain-on-lock race test, and compile-fail harness
(with paired positive controls) are all real tests, not gestures. I
verified the tree independently: `swift build --build-tests` and
`swift test` are green (45 tests, 12 suites), `swift run argon2-bench`
runs and reports honest macOS numbers (MODERATE default 0.351 s median
on an M4 Pro; end-to-end unlock 0.338 s), and the working tree is
still clean afterwards. Nearly every green gate is met as written.

The one finding I would not merge without a response is #1: the
drain-on-lock protocol is documented as guaranteeing that a straggling
read past the deadline cannot produce plaintext, and that guarantee
does not hold — every consumer copies the DEK out of the custodian's
allocation before decrypting, so force-zeroing the custodian's copy
revokes nothing from a read already in flight. The security property
is weaker than both `docs/formats.md` §Security notes and green gate 5
claim. The remainder are hardening, a latent rotation trap, and
efficiency items; none of them block on their own.

## Findings

| #   | Severity | Location                                       | Finding                                                                       |
| --- | -------- | ---------------------------------------------- | ----------------------------------------------------------------------------- |
| 1   | major    | `Sources/VaultCore/KeyCustodian.swift:47`      | Drain force-zero revokes nothing: readers decrypt against a private DEK copy   |
| 2   | minor    | `Sources/VaultCore/ChunkObject.swift:105`      | Unbounded `unpadded_length` traps on overflow instead of throwing a typed error |
| 3   | minor    | `Sources/VaultCore/SecureBytes.swift:45`       | Public `init(consumingAndZeroing:)` reinstates the ""≡"\0" KEK collision       |
| 4   | minor    | `Sources/VaultCore/SealedVault.swift:171`      | Epoch handling is single-epoch only, contradicting the normative rotation rule |
| 5   | minor    | `Sources/VaultCore/CryptoCore.swift:26`        | Sealed-plane hashing can call libsodium before `sodium_init()`                 |
| 6   | minor    | `Sources/VaultCore/Gallery.swift:169`          | Two-pass import TOCTOU: dedup hash can describe bytes that were never stored   |
| 7   | minor    | `Tests/VaultCoreTests/CorruptionMatrixTests.swift:1` | `.paddingInvalid` / `.lengthMismatch` are never exercised by any test    |
| 8   | nit      | `Sources/VaultCore/ChunkReader.swift:164`      | Per-chunk `sodium_malloc` DEK copy and per-open nonce `Array` in the hot path  |
| 9   | nit      | `Tests/VaultCoreTests/FormatConformanceTests.swift:301` | Conformance test mutates the committed fixture in place            |

---

### 1. (major) Drain force-zero does not revoke key material from in-flight reads

**Evidence.** `Sources/VaultCore/ChunkReader.swift:164-180`:

```swift
return try custodian.withKey { raw in
    let dek = try SecureBytes(zeroed: raw.count)
    dek.withUnsafeMutableBytes { dst in
        dst.baseAddress!.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
    }
    let paddedLen = try ChunkObject.open(stored: stored, ..., dek: dek, ...)
```

The decrypt at `ChunkObject.open` runs against `dek` — a *copy* — not
against the custodian's allocation. The same shape appears in
`SealedVault.swift:276-285` (`withDEK`) and, more starkly, in
`KeyCustodian.leaseKey` (`KeyCustodian.swift:85-99`), whose own comment
concedes "a straggling lease's copy zeroes at its deinit".

`KeyCustodian.lockAndDrain` (`KeyCustodian.swift:121-134`) waits for
`activeReads` up to the deadline and then `sodium_memzero`s only its
own `key`. `withKey`'s remap (`KeyCustodian.swift:63-73`) converts a
lost race to `.vaultLocked` *only if the body throws
`.authenticationFailed`*.

**Why it matters.** `docs/formats.md:296-302` states the invariant
normatively: "past the drain deadline the DEK is zeroed even if a
straggling read is mid-decrypt. The straggler's AEAD tag check then
fails and the read surfaces the typed lock error — a zeroed or
partially-zeroed key cannot produce valid plaintext." That is not what
the code does. A reader that has already taken its copy when the
deadline expires decrypts successfully and returns plaintext to `body`
*after* `lock()` has returned to the caller. Green gate 5's disjunction
("complete within the drain deadline **or** fail closed") has a third
outcome: complete *after* the deadline, with plaintext.

The window is bounded but not theoretical — the body holds a 4 MiB
`sodium_malloc` buffer and does a full-chunk AEAD open plus padding
scan; a page-fault storm or a descheduled thread pushes past 500 ms.
`LockRaceTests` cannot catch this: `lockWaitsForParkedInFlightRead`
parks *inside* `withKey` and completes before the 1 s deadline (it
asserts the drain succeeded, not that it timed out), and
`debugKeyIsZeroed` only inspects the custodian's own allocation, which
is zeroed regardless.

Note the same copy-out pattern is what makes the accepted data race
("the concurrent write to bytes libsodium is reading is accepted and
documented") mostly moot — libsodium is almost never reading the raced
bytes — but that also removes the mechanism the documented guarantee
rests on.

**Suggested fix.** Pick one and make the docs match:

- Make the guarantee real: have consumers decrypt under the
  custodian's allocation directly (an `aeadOpen` overload taking
  `UnsafeRawBufferPointer` for the key), so a force-zero mid-decrypt
  genuinely corrupts the tag; and have `withKey` re-check `locked`
  *after* `body` returns, discarding the result with `.vaultLocked` if
  the vault locked meanwhile. That last check alone closes the plaintext
  leak for both the copy and non-copy shapes and is ~4 lines.
- Or keep the design and downgrade the claim: state in
  `docs/formats.md` and in the `KeyCustodian`/green-gate-5 comments
  that `lock()` guarantees *no new reads and a zeroed custodian
  allocation*, and that a read already in flight at the deadline may
  still complete and return plaintext. Add a test that forces the
  deadline to expire (a body that sleeps past it) and asserts the
  documented outcome, so the behaviour is pinned either way.

### 2. (minor) `unpadded_length` is the one unbounded field, and overflowing it traps

**Evidence.** `Sources/VaultCore/Inventory.swift:85-89` reads the field
raw and immediately feeds it to `ChunkGeometry.chunkCount`:

```swift
let unpaddedLength = try r.u64()
...
let expected = ChunkGeometry.chunkCount(unpaddedLength: unpaddedLength, chunkSize: chunkSize)
```

`ChunkObject.swift:105-108`:

```swift
return (unpaddedLength + UInt64(chunkSize) - 1) / UInt64(chunkSize)
```

For `unpaddedLength` within `chunkSize` of `UInt64.max` this is a
trapping overflow — process abort, not a thrown error.
`ChunkGeometry.unpaddedLength(ofChunk:)` (`index * chunkSize`) and
`paddedLength` (`raw + boundary - 1`) have the same shape.

**Why it matters.** Every other body field is bounds-checked in
`parseBody` — `entry_count`, `chunk_size`, `chunk_count`,
`metadata_length` — and `docs/formats.md:180-193` documents a bound for
each of them. `unpadded_length` is documented only as "true file
length", with no bound, and gets none in code. That is a gap in the
cross-platform contract (a third-party implementer has nothing to
validate against) and the single hole in green gate 1's "oversized
declared lengths → the right typed error, never plaintext" matrix:
`CorruptionMatrixTests.inventoryParserRejectsHostileDeclaredLengths`
covers the other four fields and not this one.

I want to be precise about exploitability: `parseBody` only ever runs
on AEAD-authenticated plaintext, so an attacker without the DEK cannot
reach it. This is defense-in-depth and contract completeness, not a
live vulnerability — hence minor.

**Suggested fix.** Add a documented ceiling (e.g.
`maxFileBytes = 1 << 48`, comfortably above any media file) to
`FormatV0`, validate it in `parseBody` right after the `u64()` read
with `boundsViolation(.inventory, field: "unpadded_length")`, record it
in the `docs/formats.md` entry table, and extend the hostile-lengths
test with a fifth case.

### 3. (minor) The recommended pre-normalized password path has no empty guard

**Evidence.** `Sources/VaultCore/SecureBytes.swift:45-57`:

```swift
public init(consumingAndZeroing source: inout [UInt8]) throws {
    try self.init(zeroed: max(source.count, 1))
```

and the doc comment at `SecureBytes.swift:59-73` explicitly routes
callers here: "Callers who can supply already-normalized bytes should
use `init(consumingAndZeroing:)` directly."

**Why it matters.** With an empty `source`, `max(source.count, 1)`
yields a one-byte, all-zero buffer. `CryptoCore.deriveKEK`
(`CryptoCore.swift:140-148`) derives over `pw.count` bytes, so an empty
password and the one-byte password `"\0"` produce **the same KEK** —
precisely the collision wave-001 #13 fixed, still open on the sibling
initializer that the docs point callers at.
`ReviewRegressionTests.emptyPasswordIsRefused`
(`ReviewRegressionTests.swift:84`) only covers
`init(nfcNormalizedPassword:)`, so the regression lock has a hole
exactly where the fix wasn't applied.

**Suggested fix.** `guard !source.isEmpty else { throw VaultError.emptyPassword }`
at the top of `init(consumingAndZeroing:)` — an empty buffer is never
a legitimate input on any of its call sites (password, DEK) — then drop
the now-dead `max(source.count, 1)`, and extend the regression test to
assert both initializers refuse empty input.

### 4. (minor) Single-epoch read path contradicts the normative rotation rule

**Evidence.** Three places disagree with `docs/formats.md`:

- `docs/formats.md:163-168` is marked **normative**: "A reader MUST
  attempt AEAD open under each keyring epoch, highest first, until a
  tag verifies." `SealedVault.loadCurrentInventory`
  (`SealedVault.swift:197-208`) opens under a single `epoch` parameter,
  which `unlock` (`SealedVault.swift:171`) sets to
  `meta.currentEpoch`. There is no trial loop.
- `SealedVault.unlock` unwraps only `meta.currentEpoch`'s DEK
  (`SealedVault.swift:174`), but `ChunkReader.decryptChunk` decrypts
  each chunk under the *entry's* epoch,
  `epoch: e.epoch` (`ChunkReader.swift:173`), using that one DEK.
- `GalleryMeta.parse` accepts up to `maxKeyringEntries = 8`
  (`FormatConstants.swift:47`), and `CONTEXT.md:20-23` plus
  `docs/formats.md:94-97` both promise rotation is "a data change, not
  a format change".

**Why it matters.** The moment a second keyring epoch exists, every
entry sealed under an older epoch becomes undecryptable and surfaces as
`.authenticationFailed(.chunk)` — indistinguishable from tampering,
i.e. silent data loss presented as corruption. Nothing in the suite
covers a two-epoch keyring, so this stays invisible until the rotation
leg lands and hits it at runtime. Scoring this minor because today's
keyring is always one entry, so there is no present-tense defect — but
it is a trap laid for a future leg, and the document currently states a
rule the reference implementation does not follow, which undercuts
ADR 0001's whole premise.

**Suggested fix.** Cheapest honest option for this leg: reject
`keyring_count > 1` in the v0 parser with a typed error, and change the
"Epoch discovery" section from a MUST on readers to a statement that
v0 defines exactly one epoch with multi-epoch discovery specified when
rotation ships. Otherwise implement it properly: unwrap per-epoch DEKs
into the custodian keyed by epoch, trial-open the inventory
highest-epoch-first, and add a two-epoch fixture.

### 5. (minor) Sealed-plane hashing can run before `sodium_init()`

**Evidence.** `CryptoCore.blake2b256` (`CryptoCore.swift:26-30`) and
`Blake2bStream` (`CryptoCore.swift:36-68`) call `crypto_generichash*`
without `try SodiumRuntime.ensure()`; only `randomBytes`
(`CryptoCore.swift:19`), `SecureBytes.init(zeroed:)`
(`SecureBytes.swift:33`) and `KeyCustodian.init`
(`KeyCustodian.swift:26`) gate on it.

`SealedVault.init` (`SealedVault.swift:29-41`) allocates no
`SecureBytes` — `GalleryMeta.parse` is pure wire decoding — so
`SealedVault(directory:).auditAddresses()`, `.chunkAddresses()`, and
`.copyChunk(_:to:)` all reach `ChunkAddress.compute` →
`crypto_generichash` with libsodium uninitialized.

**Why it matters.** libsodium's documented contract is that
`sodium_init()` must precede any other call; `SodiumRuntime`'s own
comment acknowledges this. In practice `crypto_generichash` tolerates
it today, so this is a latent contract violation rather than a live
bug — but it sits on exactly the path the sealed/unlocked plane split
is designed to let external tooling use standalone, without ever
touching the plaintext plane.

**Suggested fix.** `try SodiumRuntime.ensure()` as the first statement
of `SealedVault.init(directory:clock:)` and `SealedVault.create`. It is
a one-time `dispatch_once`-equivalent, so the cost is nil.

### 6. (minor) Two-pass import TOCTOU: the dedup hash can describe bytes that were never stored

**Evidence.** `Sources/VaultCore/Gallery.swift:169-223`. Pass 1 streams
the source to compute `dedupHash` and `unpaddedLength`
(`Gallery.swift:171-179`); pass 2 rewinds (`Gallery.swift:199`) and
re-reads the source to seal chunks. The only consistency check between
passes is length: `guard got == want` (`Gallery.swift:214`).

**Why it matters.** If the source file's *contents* change between the
passes while its length stays the same, the stored ciphertext holds the
pass-2 bytes while the entry's `dedup_hash` — the sole dedup key —
describes the pass-1 bytes. That mislabeling is permanent and
self-propagating: a later import of the pass-1 content matches the
stale hash and is deduplicated onto chunks holding *different* media,
so the second file silently reads back as the first. `importFile` is
the public entry point for a photo library where the OS and other apps
can rewrite files underneath the importer, so this is not purely
theoretical.

**Suggested fix.** Keep a `Blake2bStream` running through pass 2 as
each chunk is sealed and compare its digest to pass 1's before
committing (throw a typed error on mismatch) — a few lines, no extra
I/O. Better still, drop pass 1 for the file source: hash while chunking
and patch `unpadded_length`/`dedup_hash` into the entry at commit time,
which also halves import I/O.

### 7. (minor) The padding and length validators are never tested

**Evidence.** `grep -rn "paddingInvalid\|lengthMismatch" Tests/`
returns nothing. Both errors are thrown only from
`ChunkGeometry.validatePadding` (`ChunkObject.swift:144-153`) and
`ChunkReader.readRange` (`ChunkReader.swift:107,116`), and both are
documented as part of the corruption story
(`Errors.swift:49-54`, `docs/formats.md:141-144` — "Violations are
integrity errors, not ignorable").

**Why it matters.** Green gate 1 asks that each corruption class fail
with "the right typed error". Padding validation is the check that
enforces the `docs/formats.md` §Padding contract against a
non-conforming *writer* (a third-party implementation that over-pads or
pads with non-zero bytes) — exactly the interoperability risk ADR 0001
exists to manage. As written, replacing `validatePadding`'s body with
`return` would leave the suite green.

**Suggested fix.** `ChunkGeometry.validatePadding` is a pure function
over a `SecureBytes` — three direct unit tests (non-zero pad byte →
`.paddingInvalid`; padded length one boundary too large →
`.lengthMismatch`; conforming input → no throw) cost a dozen lines and
pin the contract. The conformance test already asserts pad-exactness
from the document side (`FormatConformanceTests.swift:271-276`); this
closes the reader side.

### 8. (nit) Per-chunk guarded allocation and per-open nonce copy in the read hot path

**Evidence.** `ChunkReader.decryptChunk` (`ChunkReader.swift:164-168`)
allocates and frees a fresh `SecureBytes` — i.e. a `sodium_malloc`,
which maps guard pages and issues `mprotect`, plus `sodium_free` — for
a 32-byte DEK copy on **every** chunk decrypt. `SealedVault.withDEK`
(`SealedVault.swift:276-285`) does the same per call. Separately,
`CryptoCore.aeadOpen` (`CryptoCore.swift:114`) does
`Array(nonce).withUnsafeBufferPointer` — a heap allocation per AEAD
open, to re-materialize a slice it already has.

**Why it matters.** Purely an efficiency point (correctness is fine),
but this leg exists to underpin streaming playback: a 1 GiB video at
the 4 MiB default is 256 chunks, so 256 guard-page allocation cycles
and 256 throwaway nonce arrays per full read, on top of `verifyAuthenticity`
which does the same across every chunk of every entry. Both allocations
exist only to satisfy `borrowing SecureBytes` / `[UInt8]` signatures.

**Suggested fix.** Add a raw-pointer key overload to
`CryptoCore.aeadOpen` so `custodian.withKey`'s buffer can be passed
straight through (this also composes with finding #1's first option),
and replace `Array(nonce)` with
`nonce.withUnsafeBufferPointer { ... }` on the rebased slice.

### 9. (nit) The conformance test opens the committed fixture in place

**Evidence.** `FormatConformanceTests.referenceImplementationReadsFixture`
(`FormatConformanceTests.swift:301-317`) resolves the fixture via
`#filePath` (`FormatConformanceTests.swift:24-28`) — the source tree,
not `Bundle.module` — and calls `SealedVault(directory:)` on it, which
runs `Recovery.recover` (deletes `wal/*` and `HEAD.tmp`,
`Store.swift:251-259`), and `unlock`, which can write
`unlock.throttle` into that directory (`RateLimiter.swift:50-58`).

**Why it matters.** Today this is benign — I confirmed `git status` is
clean after a full `swift test` — because the fixture's HEAD is valid
and the unlock succeeds. But the test suite is one fixture-corruption
or one wrong-password conformance case away from mutating committed
files as a side effect, and `loadCurrentInventory`'s HEAD-repair path
(`SealedVault.swift:226-230`) would write into the repo. That is a
surprising property for a test whose whole job is asserting the fixture
is stable.

**Suggested fix.** Copy the fixture directory into a temp dir in the
test and open the copy — three lines, and it makes the read-only
intent structural rather than incidental. (`Package.swift`'s
`.copy("Fixtures")` already stages a bundle copy; note it must stay
regardless, since it is what generates the `Bundle.module` that
`CompileFailTests` depends on.)

---

## Verified, not findings

Recorded so the reconciliation pass knows these were checked rather
than skipped:

- `swift build --build-tests` and `swift test` are green from a clean
  checkout (45 tests / 12 suites, 2.4 s). Only pre-existing warnings.
- `swift run -c release argon2-bench` runs and reports plausible
  numbers; green gate 8 is met and the "macOS numbers only, device
  envelope deferred" framing is honest.
- Working tree remains clean after build, test, and benchmark runs.
- The `~Copyable` feasibility spike (WS A.2) is real and its S1–S4
  claims match what the production types actually do.
- The compile-fail harness genuinely invokes `swiftc -emit-sil`, checks
  for specific diagnostics, and enforces the negative/control pairing
  rule as a test rather than a convention.
- `readRange`'s overflow guard (`ChunkReader.swift:91-95`) correctly
  fixes wave-001 #1; I re-derived it against `offset == UInt64.max`.
- `FS.read`'s fstat-then-capped-read (`Store.swift:93-118`) has no
  TOCTOU window, as claimed.
- The single-writer claim (`claimWriter`) and drain-aware `KeyLease`
  do fix wave-001 #2 and #5 as described.
- Rollback via a restored older HEAD+inventory pair is correctly
  scoped out in `docs/formats.md:254-257` rather than silently ignored.

REVIEW COMPLETE

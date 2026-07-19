# Blind code review — CED-10 VaultCore (claude-code, wave-001)

## Verdict

This is a strong, unusually disciplined first leg. The format is genuinely
normative (`docs/formats.md` is specific enough that the conformance test
re-decodes the committed fixture vault from the document alone, which is the
real proof the cross-platform contract works), the crypto choices match the
amended spec exactly (XChaCha20-Poly1305 with random per-chunk nonces,
positional AAD, Argon2id with pre-allocation bounds validation, domain-separated
dedup hash), and the corruption matrix, crash-consistency failpoints, and
compile-fail-with-paired-controls harness all do what they claim. `swift test`
is green (40 tests, 11 suites) on the pinned 6.2 toolchain. The findings below
are real defects rather than gaps in ambition: two confirmed by running code —
a public-API arithmetic overflow that aborts the process, and a documented-but-
unenforced misuse that silently discards a committed import — plus a
bounds-check-after-allocation in the file reader that undercuts the "hostile
bytes cannot demand pathological allocations" property the goal states twice.
The remaining items are custody-boundary honesty issues (plaintext and DEK
copies that outlive `lock()`) and test-coverage claims that overstate what is
actually asserted. Nothing here invalidates the design; #1–#3 should be fixed
before this becomes the foundation everything else layers on.

## Findings

| #   | Severity | Location                                      | Finding                                                                   |
| --- | -------- | --------------------------------------------- | ------------------------------------------------------------------------- |
| 1   | major    | `Sources/VaultCore/ChunkReader.swift:88`      | `readRange` traps on offset overflow — public API aborts the process      |
| 2   | major    | `Sources/VaultCore/UnlockSession.swift:35`    | Two `Gallery` instances silently discard a committed import               |
| 3   | major    | `Sources/VaultCore/Store.swift:74`            | `FS.read` enforces `maxBytes` only after loading the whole file           |
| 4   | minor    | `Sources/VaultCore/Inventory.swift:173`       | Decrypted metadata blobs live in ordinary heap and survive `lock()`       |
| 5   | minor    | `Sources/VaultCore/KeyCustodian.swift:79`     | `keyCopy()` escapes read custody, weakening the drain guarantee           |
| 6   | minor    | `Sources/VaultCore/KeyCustodian.swift:101`    | Force-zero races in-flight decrypts (UB); straggler can return plaintext  |
| 7   | minor    | `Sources/VaultCore/SealedVault.swift:21`      | Caller-injectable `VaultClock` neutralizes the unlock rate limiter        |
| 8   | minor    | `Tests/VaultCoreTests/LockRaceTests.swift:90` | Drain-wait test does not exercise the drain wait                          |
| 9   | minor    | `Sources/VaultCore/SecureBytes.swift:64`      | NFC normalization leaves an unzeroed intermediate `String`                |
| 10  | nit      | `Sources/VaultCore/RateLimiter.swift:56`      | Throttle state unsynced and trusts a future-dated timestamp               |
| 11  | nit      | `Sources/VaultCore/Store.swift:50`            | `fsyncDir` swallows errors though the doc calls the ordering normative    |
| 12  | nit      | `CONTEXT.md:11`                               | Glossary documents a `galleries/{id}/` layout the code does not implement |
| 13  | nit      | `Sources/VaultCore/SecureBytes.swift:45`      | Empty password and single-NUL password derive the same KEK                |

---

### 1. major — `readRange` traps on offset overflow, aborting the process

**Evidence:** `Sources/VaultCore/ChunkReader.swift:88`

```swift
guard length > 0, offset + UInt64(length) <= e.unpaddedLength else {
    throw VaultError.rangeOutOfBounds
}
```

`offset` is caller-supplied `UInt64` on a public API. `offset + UInt64(length)`
uses Swift's trapping `+`, so any offset near `UInt64.max` crashes before the
bounds check can reject it.

Confirmed by running a temporary test against the built package (removed
afterwards; tree left clean):

```
REPRO: calling readRange(offset: UInt64.max - 4, length: 8)
error: Exited with unexpected signal code 5      # SIGTRAP
```

The process died — no `VaultError` was thrown.

**Why it matters:** every other bounds path in this package is meticulous about
turning hostile or wrong input into a typed error; this one turns it into
process death. The natural caller is a media player passing a seek offset
computed from user input or from a partially-parsed container, which is exactly
where a garbage offset arrives. In an iOS photo vault that is an availability
bug in the read path, and it bypasses the `rangeOutOfBounds` contract the error
enum advertises.

**Suggested fix:** use the non-trapping form and check before adding:

```swift
let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
guard length > 0, !overflow, end <= e.unpaddedLength else {
    throw VaultError.rangeOutOfBounds
}
```

Worth adding an overflow case to the corruption-matrix or a range-bounds test so
it stays fixed.

---

### 2. major — Two `Gallery` instances from one session silently discard a committed import

**Evidence:** `Sources/VaultCore/UnlockSession.swift:35-39`, `Sources/VaultCore/Gallery.swift:244-259`

`openGallery()` is a non-consuming method that mints a fresh `Gallery` each
call, seeded with a _copy_ of the session's inventory. `commitAppending` builds
`next` from that private copy and rewrites HEAD wholesale. Two instances
therefore each commit "their" inventory, and the later commit erases the
earlier's entry. The hazard is documented in prose on line 37 ("One `Gallery`
per session — imports from two Gallery instances of one vault would race the
inventory") but nothing prevents it.

Confirmed by running a temporary test (removed afterwards):

```
REPRO: imported A=7a2e5cac-… B=56a8b6c7-…; on disk after reopen = [56a8b6c7-…]
REPRO: file count on disk = 1 (expected 2)
REPRO:   7a2e5cac-… present=false
REPRO:   56a8b6c7-… present=true
```

Both `importBytes` calls returned a `FileID` successfully. Import A's chunks
were published into the CAS and its entry then vanished, leaving orphan chunks
and no error anywhere.

**Why it matters:** this is silent data loss in a photo vault — the API reports
success for an import the user can never see again. It also contradicts the
package's own design ethos: the team built a whole compile-fail harness to make
use-after-lock and double-lock _compile errors_, yet the single most
consequential misuse is prevented only by a doc comment. It is also reachable
without obvious misuse — two view controllers each calling `openGallery()` on a
shared session looks entirely reasonable from the outside.

**Suggested fix:** make single-writer-ness structural rather than advisory.
Cheapest option that fits the existing move-only vocabulary: make `openGallery()`
`consuming` (or have the session vend the gallery exactly once and cache it), so
a second call is a compile error and joins the existing fixture set. If the
session must stay usable, have `Gallery` register itself with the custodian and
throw a typed `galleryAlreadyOpen` on the second call. Independently,
`commitAppending` should re-read HEAD's generation and refuse to commit when it
has moved (a compare-and-swap on `generation`), which also hardens the
single-process assumption noted in `SealedVault.swift:9-11`.

---

### 3. major — `FS.read` enforces `maxBytes` only after the whole file is in memory

**Evidence:** `Sources/VaultCore/Store.swift:74-87`

```swift
static func read(_ url: URL, object: VaultObjectKind, maxBytes: Int = .max) throws -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: url.path) else { … }
    guard data.count <= maxBytes else {
        throw VaultError.boundsViolation(object, field: "object_length")
    }
    return [UInt8](data)
}
```

`FileManager.contents(atPath:)` reads the entire file into memory first; the
bound is then checked on the already-materialized `Data`, and the successful
path allocates a second full copy via `[UInt8](data)`. Every caller that passes
a deliberate bound is defeated: `SealedVault.init` (`maxBytes: 64 * 1024` for
`gallery.meta`, `SealedVault.swift:28`), `loadCurrentInventory`
(`maxBytes: FormatV0.maxInventoryObjectBytes`, `SealedVault.swift:181-183`), and
`ChunkReader.decryptChunk` (`headerLength + chunkSize + tag`,
`ChunkReader.swift:155-157`).

**Why it matters:** the goal states this property twice as a deliberate hardening
(Codex A8: "hostile metadata cannot request pathological allocations"; Codex
B13: "validated against hard bounds before any allocation"), and `docs/formats.md:80`
makes it normative. The threat model that justifies the entire corruption matrix
is an attacker who can write the vault directory — the same attacker replaces a
64 KiB `gallery.meta` or a 4 MiB chunk with a multi-gigabyte file and gets an
OOM kill on a memory-constrained iOS device, before any typed error can fire.
The declared-length bounds in the parsers are correct; it is the file-size bound
that is enforced too late.

**Suggested fix:** stat first, or read incrementally:

```swift
static func read(_ url: URL, object: VaultObjectKind, maxBytes: Int = .max) throws -> [UInt8] {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attrs?[.size] as? Int, size > maxBytes {
        throw VaultError.boundsViolation(object, field: "object_length")
    }
    …
}
```

A `FileHandle`-based bounded read is more robust still (it closes the TOCTOU
between stat and read). Also consider giving `copyChunk` and `auditAddresses`
(`SealedVault.swift:89`, `:111`) a real bound — they currently pass the default
`.max`, so a hostile CAS entry is read whole regardless.

---

### 4. minor — Decrypted metadata blobs live in ordinary heap and survive `lock()`

**Evidence:** `Sources/VaultCore/Inventory.swift:170-176`

```swift
// The body is structural data (addresses, lengths, app blobs) —
// parsed into ordinary memory by design; content plaintext
// never flows through the inventory.
let body = plain.withUnsafeBytes { raw in
    Array(UnsafeRawBufferPointer(rebasing: raw[0..<n]))
}
```

The comment is accurate about chunk content but not about the app metadata blob.
`InventoryEntry.metadata` is a plain `[UInt8]` (`Inventory.swift:29`), retained
for the session's lifetime by `Gallery.inventory`, `ChunkReader.entries`
(`ChunkReader.swift:42`), and `UnlockSession.inventory`. `lock()` zeroes only
the custodian's DEK (`KeyCustodian.swift:101`) — nothing zeroes these arrays,
and the intermediate `body` array is likewise never zeroed before dealloc. The
accessors do fail closed after lock (`ChunkReader.swift:117-120`), but the bytes
remain in the heap.

That this blob is user plaintext is settled by the project's own fixture, which
stores `name=alpha.jpg` and `name=empty.dat` there
(`FormatConformanceTests.swift:51-55`) — filenames, and in a photo vault
plausibly captions, locations, and EXIF.

**Why it matters:** green gate 3 is explicitly scoped to disk observation, so
this is not a gate violation — the custody canary test even plants the canary in
metadata (`CustodyCanaryTests.swift:47`) and passes precisely because it scans
files, not memory. But it means `lock()` does not do what the glossary and
`UnlockSession`'s doc comment imply for the plaintext plane, and the code comment
asserting a stronger property than holds will mislead the next reader.

**Suggested fix:** either hold metadata in `SecureBytes` and serve it through a
scoped borrowing closure (consistent with how chunk plaintext is already
handled), or — if ordinary memory is an accepted trade — correct the comment to
say so explicitly and record the limitation in `docs/formats.md` §Security notes
beside the existing mlock/`sodium_malloc` policy. At minimum `body` should be
zeroed after `parseBody` returns.

---

### 5. minor — `keyCopy()` escapes read custody, weakening the drain guarantee

**Evidence:** `Sources/VaultCore/KeyCustodian.swift:79-87`, used at `Sources/VaultCore/Gallery.swift:219`, `:252`

`withKey` holds custody only for the duration of its closure, so the
`SecureBytes` copy `keyCopy()` returns outlives the `activeReads` window that
`lockAndDrain` waits on. An import in its chunk loop holds a live DEK copy that
`lockAndDrain` neither counts nor zeroes; it goes on sealing and staging chunks
with the correct key after `lock()` has returned and reported success.

**Why it matters:** green gate 5 asserts "the DEK allocation is provably zeroed
after drain", and `debugKeyIsZeroed` (`KeyCustodian.swift:107`) faithfully
reports that — for one allocation. Live copies elsewhere make the claim narrower
than it reads. The blast radius is small (`commitAppending` re-checks
`isLocked`, so the post-lock work is discarded rather than committed), but the
invariant the test proves is not the invariant the gate states.

**Suggested fix:** have `keyCopy()` register the copy with the custodian
(e.g. a token whose deinit decrements `activeReads`, so the drain actually waits
on it), or restructure the two `Gallery` call sites onto `withKey` so custody
brackets the whole sealing operation. If the copies are deliberate, narrow the
gate wording and the `debugKeyIsZeroed` doc comment to "the custodian's
allocation".

---

### 6. minor — Force-zero races in-flight decrypts; a straggler can still return plaintext

**Evidence:** `Sources/VaultCore/KeyCustodian.swift:99-103`

```swift
while activeReads > 0, cond.wait(until: limit) {}
// Drained — or deadline passed with stragglers; zero either way.
sodium_memzero(key, CryptoCore.keyBytes)
```

Two distinct issues, both by design but neither disclosed:

1. When the deadline expires with `activeReads > 0`, `sodium_memzero` writes the
   same memory that an in-flight `crypto_aead_xchacha20poly1305_ietf_decrypt` is
   concurrently reading (`ChunkReader.swift:159-168` holds custody across the
   whole AEAD call). That is an unsynchronized read/write on the same bytes — a
   data race and undefined behavior under the C and Swift memory models, and
   something ThreadSanitizer will flag if CI ever enables it. The remapping at
   `KeyCustodian.swift:62-72` handles the _outcome_ but not the race itself.
2. A straggler that finishes decrypting after the deadline but before the zero
   lands returns real plaintext to its caller, after `lock()` has already
   returned. The spec's phrasing ("complete within the drain deadline or fail
   closed") does not cover completing _outside_ it.

**Why it matters:** the design is defensible — bounded blocking beats unbounded
— but "we deliberately race here" should be a written decision, not an emergent
one, especially since the remapping code shows the race was anticipated.

**Suggested fix:** document both in `docs/formats.md` §Security notes and in
`lockAndDrain`'s doc comment. If the UB is unacceptable, make the key pointer
itself the synchronization point: swap in a null/sentinel under `cond` and have
`withKey` re-check it, so a straggler's dereference is ordered rather than
racing. Add a test that forces the deadline to expire (e.g. a failpoint that
parks a reader inside `withKey`) and asserts the outcome is `vaultLocked`.

---

### 7. minor — Caller-injectable `VaultClock` neutralizes the unlock rate limiter

**Evidence:** `Sources/VaultCore/SealedVault.swift:21`, `:39-44`, `:148`; `Sources/VaultCore/RateLimiter.swift:4-9`

`VaultClock` is public with a public initializer, and both `SealedVault.init`
and `SealedVault.create` take it as a public parameter. It feeds exactly one
consumer — the unlock rate limiter (`SealedVault.swift:148`). Any caller can
pass `VaultClock { .greatestFiniteMagnitude }` and every cooldown check at
`RateLimiter.swift:72` passes unconditionally.

**Why it matters:** this is a test seam (its doc comment says so: "Injectable
time source so rate-limit tests never sleep") promoted into the public API of a
security control. The rate limiter is already honestly scoped as best-effort —
`RateLimiter.swift:20-22` and `docs/formats.md:271-276` both note an attacker
with filesystem access can delete the sidecar — but a bypass that needs no
filesystem access at all, only the public API, is worth closing since it costs
nothing.

**Suggested fix:** drop `clock` from the public initializers and inject it
through an internal init or `@testable` seam; the tests already use
`@testable import VaultCore`, so nothing in the suite needs the public
parameter. If it stays public, say plainly in the doc comment that supplying a
non-system clock disables backoff.

---

### 8. minor — The drain-wait test does not exercise the drain wait

**Evidence:** `Tests/VaultCoreTests/LockRaceTests.swift:90-122`

The test named `lockWaitsForInFlightReadWithinDeadline` concedes in its own
comment that it does not do this:

```swift
// A slow reader: holds read custody ~100 ms (inside the body,
// key custody is already released — so emulate slowness by a
// read storm instead; here we simply verify lock() returns
// with the key zeroed and a subsequent read fails closed).
```

Its assertions are `lockDuration < 0.6`, `debugKeyIsZeroed`, and that completed
reads were correct. Nothing asserts that `lock()` _waited_ for an in-flight read
— an implementation that dropped the `while activeReads > 0, cond.wait(…)` loop
at `KeyCustodian.swift:99` entirely and zeroed immediately would pass both tests
in this suite.

**Why it matters:** drain-on-lock is the headline concurrency amendment of this
goal (Codex B5, green gate 5), and the wait branch — the part that distinguishes
drain-on-lock from zero-on-lock — has no regression protection. The sibling test
`concurrentReadersDuringLockCompleteOrFailClosed` covers fail-closed behavior
well, so this is the one uncovered half.

**Suggested fix:** add an internal test hook that parks a reader inside
`withKey` (a `TestSupport`-only barrier closure, in the spirit of the existing
`CommitFailpoint`), then assert `lock()` blocked for at least the reader's hold
time and that the reader completed successfully. Rename the test if it keeps its
current weaker scope.

---

### 9. minor — NFC normalization leaves an unzeroed intermediate `String`

**Evidence:** `Sources/VaultCore/SecureBytes.swift:63-66`

```swift
public init(nfcNormalizedPassword password: String) throws {
    var bytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
    try self.init(consumingAndZeroing: &bytes)
}
```

`precomposedStringWithCanonicalMapping` allocates a second `String` holding the
password in plain heap memory. Only the derived `bytes` array is zeroed; the
normalized `String`'s storage is deallocated without being wiped, as is any
intermediate the bridged NFC transform makes.

**Why it matters:** Codex A5 asks for "NFC-normalized UTF-8 bytes in a
zeroed-after-use buffer, never a retained Swift `String`". The letter is met —
VaultCore does not _retain_ one — but the spirit (no unwiped password copies in
ordinary heap) is not, and the doc comment's "VaultCore never retains the
`String`" reads as a stronger guarantee than the code provides. Fully closing
this needs a byte-level NFC path and may not be worth it; being accurate about
it is.

**Suggested fix:** amend the doc comment to name the intermediate explicitly,
and offer a `SecureBytes(nfcNormalizedPasswordBytes: inout [UInt8])` overload so
callers who can supply already-normalized bytes never construct a `String` at
all. Record the residual exposure in `docs/formats.md` §Security notes.

---

### 10. nit — Throttle state unsynced, and a future-dated timestamp is trusted

**Evidence:** `Sources/VaultCore/RateLimiter.swift:50-57`, `:67-75`

`store` writes with `fsync: false`, so a power loss after a burst of failed
unlocks can lose the accumulated counter. Separately, `checkAllowed` computes
`readyAt = s.lastFailureAt + cooldown` and compares against `clock.now()` with
no sanity bound on `lastFailureAt`; a sidecar with a far-future timestamp (clock
skew, or a hostile write) locks unlock out indefinitely — a self-inflicted DoS
on the legitimate user, the opposite of the control's purpose.

**Suggested fix:** fsync the sidecar on write (it is one small file on a path
that is already slow), and clamp: treat `lastFailureAt > now` as `now` and
proceed, rather than honoring it.

---

### 11. nit — `fsyncDir` swallows errors though the doc calls the ordering normative

**Evidence:** `Sources/VaultCore/Store.swift:50-55`

```swift
_ = fsync(fd)  // directory fsync is advisory on some filesystems
```

`fsyncFile` throws `ioFailure` on failure; `fsyncDir` discards the result. But
`docs/formats.md:225-226` states "fsync ordering is normative: object file →
its parent directory → HEAD → HEAD's parent directory." A silently failing
directory sync means the durability the commit protocol promises may not hold,
and no test asserts the ordering (the failpoint tests exercise _sequence_, not
_durability_ — they simulate crashes with a thrown error inside one process, so
page-cache state is never actually at risk).

**Suggested fix:** align the two — either surface directory-sync failures as
`ioFailure`, or soften the doc to mark directory syncs best-effort and say why.
A note in the crash-consistency suite that fault injection simulates abort, not
power loss, would set expectations honestly.

---

### 12. nit — Glossary documents a `galleries/{id}/` layout the code does not implement

**Evidence:** `CONTEXT.md:11` ("its own password, DEK, and on-disk directory
(`galleries/{id}/`)"), versus `Sources/VaultCore/Store.swift:11-19`, where
`VaultLayout` treats the caller-supplied directory as the gallery root, and
`docs/formats.md:41` which correctly writes `{gallery-root}/`.

The goal's Workstream C.7 also says "On-disk layout per spec §6
(`galleries/{id}/gallery.meta`, …)". The flat design looks like the better call
— multi-gallery containment is the app shell's concern, not the portable core's
— but the glossary now describes a path that does not exist.

**Suggested fix:** update `CONTEXT.md` to say a gallery is a directory whose
path the embedder chooses, and note in RESULT.md that the `galleries/{id}/`
container is deferred to the App Shell leg.

---

### 13. nit — Empty password and single-NUL password derive the same KEK

**Evidence:** `Sources/VaultCore/SecureBytes.swift:45-47`

```swift
try self.init(zeroed: max(source.count, 1))
```

An empty password produces a 1-byte buffer holding `0x00` with `count == 1`, and
`deriveKEK` passes `pw.count` as the password length
(`CryptoCore.swift:144`) — so `""` and `"\u{0}"` hash identically. Harmless in
practice (both are degenerate passwords, and the KDF still runs), but it is a
silent input collision in a security primitive.

**Suggested fix:** reject an empty password with a typed error at the
`nfcNormalizedPassword` boundary, or carry an explicit length alongside the
buffer so the `max(_, 1)` padding is never mistaken for content.

REVIEW COMPLETE

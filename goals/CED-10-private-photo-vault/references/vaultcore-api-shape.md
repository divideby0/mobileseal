# VaultCore public API shape — ADHD session 001 synthesis

Converged direction from `adhd/session-001-20260719-132924/` (5 diverge
frames, 3 deepened branches — full idea pool and focus sketches in that
folder's `*/output.json`). The three top-scoring directions compose into
one layered design rather than competing:

## The composed shape

1. **Two-plane split (bonded warehouse).** `SealedVault` is the
   ciphertext plane: constructible from a directory URL alone; can
   enumerate/copy chunks, verify BLAKE2b addresses, structurally parse
   `gallery.meta` (incl. epoch), and run a public `fsck`/FormatVerifier
   — all with no DEK. Sync, backup, integrity audit, and the future
   CLI peer compile against this plane only, making zero-knowledge
   sync structurally checkable. The plaintext plane is reachable only
   via `SealedVault.unlock(password:)`.

2. **Type-state session + scoped plaintext custody.** `unlock` returns
   a move-only (`~Copyable`) `UnlockSession`: `lock()` is a
   `consuming func` that `sodium_memzero`s the DEK; deinit self-zeroes;
   use-after-lock is a compile error. The DEK lives only in
   `sodium_malloc`/`mlock`-backed `SecureBytes` (itself `~Copyable`,
   zero-on-deinit); plaintext exits only through scoped
   `withDecryptedChunk { borrowing SecureBytes }` closures, with a
   caller-declared resident-plaintext budget for streaming.

3. **Single-writer actor + immutable snapshots.** A `Gallery` actor is
   the only holder of write authority: mutations stage into
   `wal/{txid}/`, fsync, and become visible via one atomic rename +
   HEAD swap (half-finished import = deletable staging dir, never a
   corrupt vault). Every mutation returns a new immutable, Sendable
   `Manifest` value (published via `AsyncStream<Manifest>`); reads are
   decrypt-only against a snapshot and run off-actor in parallel —
   video scrubbing never queues behind an import.

4. **Revocable read capability (the seam between 2 and 3).** Off-actor
   readers hold a `ChunkReader` capability wrapping the DEK behind a
   generation counter; lock/backgrounding bumps the generation and
   zeroes the shared buffer, so stale readers fail closed with a typed
   `VaultLocked` error. This resolves the actor-snapshot design's
   load-bearing risk (key material outliving lock) without
   re-serializing reads.

## Load-bearing risks (named, owned)

- **Swift `~Copyable` maturity**: non-copyable types don't fit generic
  containers/escaping closures well, and AVAssetResourceLoader is a
  cross-thread callback API. Mitigation: exactly one audited actor
  facade (`StreamingSessionActor`) is the sanctioned escape hatch;
  compile-fail tests (a swiftc negative-compilation harness over a
  misuse matrix: use-after-lock, Sendable capture, SecureBytes copy)
  keep the guarantees regression-tested.
- **Two verification tiers must not blur**: the sealed plane proves
  address/structural integrity only (`auditAddresses()`); AEAD
  authenticity needs the DEK (`session.verifyAuthenticity()`). Name
  them distinctly or sync tooling will treat sealed-green as
  end-to-end integrity.
- **Scoped custody is honest, not absolute**: `withBytes` callers can
  still copy out; the design narrows and greps the plaintext surface,
  it doesn't abolish caller discipline.

## First steps (from the focus branches)

1. `SecureBytes` first — sodium_malloc/mlock/memzero `~Copyable`
   buffer + zeroed-before-free test + compile-fail harness.
2. `Manifest`/`FileEntry`/`ChunkRef` immutable Sendable value types +
   `GalleryActor.commit` skeleton with WAL-rename semantics and a
   monotonic-snapshot test.
3. `SealedVault` + `UnlockSession` split proven by a test target that
   imports only sealed-plane symbols and round-trips a chunk copy
   against a locked fixture vault.

## Child ideas worth carrying on the map (not this goal)

- Sealed-plane have/want diff format now → sync leg integration-tests
  against locked fixture vaults (feeds Local Peer Sync).
- Two-tier `fsck` as the CLI peer's first command (`fsck` sealed /
  `--deep` unlocked) (feeds CLI leg).
- WAL-as-sync-outbox: committed `wal/{txid}` batches are exactly the
  resumable upload unit (feeds sync legs).
- Snapshot pinning as GC roots (feeds a future tombstone-GC leg).
- Capability subsets: read-only `DecryptToken` for playback, write-only
  `ImportToken` for a share extension (feeds App Shell/Playback legs).
- Deterministic actor replay tests as a cross-platform conformance
  suite (feeds CLI leg).
- Chunk-count/size bucketing so a sealed vault leaks minimal shape
  info (decide before the sync format ships).
- Dynamic resident-plaintext budget tied to memory-pressure
  notifications (feeds Playback leg).
- Auto-lock as lease renewal (backgrounding/timeout) atop the
  generation counter (feeds App Shell leg, spec §11).

## Post-review amendments (2026-07-19, after blind Codex plan review)

The composed shape above stands, with four amendments from
`codex-plan-review-20260719.md` (accepted by cedric in chat):

1. **Drain-on-lock** (B5): `lock()` refuses new reads immediately,
   waits up to ~500 ms for in-flight reads, then force-zeroes the DEK;
   readers that lose the race fail closed with a typed lock error.
   The generation counter alone is not the synchronization mechanism —
   key lifetime is reference-held during a read and released at read
   end or drain deadline, whichever first.
2. **Snapshot metadata custody** (B6): immutable inventory snapshots
   carry encrypted metadata blobs and structural refs only; decrypted
   names/dates/hashes are produced by session-scoped accessors and are
   not retained inside Sendable snapshot values, so lock revokes
   metadata access along with content access.
3. **Streaming scope trimmed** (A6): the resident-plaintext budget and
   `StreamingSessionActor` move to the playback leg. CED-10 ships only
   a minimal chunk-range read seam plus a test proving that custody
   machinery can layer on without API breakage.
4. **Secure-memory failure policy** (Q7): `sodium_malloc` failure
   aborts unlock with a typed error; `mlock` failure logs and
   proceeds (page-locking is best-effort on iOS).

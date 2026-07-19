# CodeRabbit findings

Notice: Detected claude environment. Use `coderabbit review --agent` for structured agent-friendly output.
Connecting to CodeRabbit... 0s elapsed
Preparing review... 1s elapsed
────────────────────────────────────────
CodeRabbit Review

Diff      : committed changes only
Compare   : CED-10-private-photo-vault → main
Directory : CED-10-private-photo-vault
────────────────────────────────────────

(\(\
(• .•)  Ripgrepping your code for bugs.

Summarizing changes... 3s elapsed
Writing review comments... 42s elapsed
Writing review comments... 1m 00s elapsed - still working

────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/prompt.md:3-9]8;;

  Update the stale absolute paths.

  The context and output paths still point to the old
  goals/drafts/20260718-164118-private-photo-vault worktree, while this
  goal uses goals/CED-10-private-photo-vault/.... Execution can therefore
  fail to read the required files or write output.json where the stack
  expects it. Use repository-relative paths or derive them from the prompt’s
  location.


  Proposed path correction

  -CONTEXT FILES ... /goals/drafts/20260718-164118-private-photo-vault/goals/drafts/20260718-164118-private-photo-vault/GOAL.md ...
  +CONTEXT FILES ... goals/CED-10-private-photo-vault/GOAL.md, goals/CED-10-private-photo-vault/references/intake.md ...
  ...
  -Write the JSON array to: /.../goals/drafts/20260718-164118-private-photo-vault/.../regulator/output.json
  +Write the JSON array to: goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/output.json


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/docs/adr/0001-portable-core-formats-as-contract.md:54docs/adr/0001-portable-core-formats-as-contract.md:54-56]8;;

  Correct the stale specification reference.

  docs/formats.md has no §5.1. Point this to its Algorithms section so
  the crypto-dependency rationale remains traceable.


────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/Tests/VaultCoreTests/FormatConformanceTests.swift:150Tests/VaultCoreTests/FormatConformanceTests.swift:150-153]8;;

  Commit the fixture assets this test requires.

  The supplied stack lists only Fixtures/kat-vault/expected.json; it does
  not include gallery/ or file-a.bin. The generator is disabled by
  default, so this test will fail opening gallery.meta, HEAD, objects,
  and plaintext input. Commit the complete fixture vault and file-a.bin
  alongside the manifest.






  Also applies to: 192-199, 243-246


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/docs/formats.md:146docs/formats.md:146-159]8;;

  Make the inventory sealing epoch discoverable.

  epoch is required to construct Inventory AAD, but it exists only inside
  the ciphertext being opened. Once rotation creates multiple keyring
  entries, an independent reader cannot select the DEK/AAD epoch from the
  documented header or HEAD; this contradicts the claim that every stored
  object names its epoch.

  Add a cleartext inventory-header epoch (requiring a format/fixture
  update), or normatively specify authenticated trial-decryption across
  keyring epochs. The current format leaves cross-platform rotation behavior
  ambiguous.






  Also applies to: 161-162, 171-178


────────────────────────────────────────────────────────────────────────
  major [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/Tests/VaultCoreTests/FormatConformanceTests.swift:264Tests/VaultCoreTests/FormatConformanceTests.swift:264-273]8;;

  Assert the exact tail padding length.

  The current bounds accept any boundary-sized tail up to chunkSize. For
  example, a one-byte tail may incorrectly retain multiple 64 KiB blocks.
  The format requires padding to exactly the next boundary (minimum one), so
  this green gate can pass a nonconforming writer.


  Proposed fix

                   let isTail = index == addresses.count - 1
                   let content =
                       isTail
                       ? Int(unpaddedLength) - index * Int(chunkSize)
                       : Int(chunkSize)
  -                #expect(padded.count % Self.paddingBoundary == 0)
  -                #expect(padded.count >= Self.paddingBoundary)
  -                #expect(padded.count <= Int(chunkSize))
  +                let expectedPaddedLength = max(
  +                    Self.paddingBoundary,
  +                    ((content + Self.paddingBoundary - 1) / Self.paddingBoundary)
  +                        * Self.paddingBoundary)
  +                #expect(padded.count == expectedPaddedLength)
                   #expect(padded[content...].allSatisfy { $0 == 0 }, "pad bytes must be zero")


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/references/intake.md:245goals/CED-10-private-photo-vault/references/intake.md:245-252]8;;

  Use valid PostgreSQL uniqueness constraints for invites.

  PRIMARY KEY (gallery_id, coalesce(phone, email)) is not a valid
  PostgreSQL primary-key definition because primary keys cannot contain
  expressions. Use a surrogate key, require exactly one contact field, and
  add partial unique indexes for (gallery_id, phone) and `(gallery_id,
  email)`.


────────────────────────────────────────────────────────────────────────
  minor [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/wayfinder/MAP.md:33goals/CED-10-private-photo-vault/wayfinder/MAP.md:33-37]8;;

  Keep CED-10 benchmark scope macOS-only.

  GOAL.md defers the 0.5–1 second device envelope to the App Shell leg and
  requires CED-10 to report honest macOS timing. Replace “on-device Argon2id
  benchmark harness” with the macOS benchmark target.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/10-year-old/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/10-year-old/prompt.md:3-9]8;;

  Use repository-relative generation paths.

  These paths point to the old goals/drafts/... worktree rather than the
  committed goals/CED-10-private-photo-vault/... tree. Re-running the
  prompt elsewhere will fail to locate its inputs and output.


────────────────────────────────────────────────────────────────────────
  minor [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/wayfinder/MAP.md:108goals/CED-10-private-photo-vault/wayfinder/MAP.md:108-110]8;;

  Update the stale format-contract status.

  CED-10 now commits docs/formats.md with canonical encodings, bounds, and
  known-answer vectors. Leaving this under “Not yet specified” can cause a
  later leg to reopen a contract that is already locked.


────────────────────────────────────────────────────────────────────────
  minor [Functional Correctness]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/10-year-old/output.json:1goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/10-year-old/output.json:1-26]8;;

  Emit all six requested ideas.

  The paired prompt requires six JSON objects, but this output contains only
  five. Add the missing idea or correct the prompt/count.


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/references/vaultcore-api-shape.md:28goals/CED-10-private-photo-vault/references/vaultcore-api-shape.md:28-35]8;;

  Align the first-step API names with the CED-10 inventory boundary.

  The current goal defines Inventory/Entry for this leg and reserves
  Manifest-CRDT for later, but these sections still make
  Manifest/FileEntry the first implementation surface. Unless this is an
  explicitly documented temporary alias, it risks incompatible public
  symbols and premature CRDT semantics.






  Also applies to: 65-69


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/3am-on-call/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/3am-on-call/prompt.md:3-9]8;;

  Use repository-relative generation paths.

  These paths point to the old goals/drafts/... worktree rather than the
  committed goals/CED-10-private-photo-vault/... tree. Re-running the
  prompt elsewhere will fail to locate its inputs and output.


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/references/intake.md:91goals/CED-10-private-photo-vault/references/intake.md:91-98]8;;

  Mark the superseded crypto guidance in the source specification.

  This preserved handoff still presents DEK wrapping as a vague
  “crypto_secretbox equivalent,” mandates deterministic `(fileID,
  chunkIndex)` nonces, and leaves convergent addressing open. The locked
  CED-10 contract selects explicit XChaCha20-Poly1305 parameters, random
  nonces, AAD, and ciphertext-hash addressing. Add an in-place supersession
  notice so future implementers cannot copy the obsolete rules.






  Also applies to: 124-138


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/GOAL.md:153goals/CED-10-private-photo-vault/GOAL.md:153-157]8;;

  Make the HEAD corruption gate compatible with deferred rollback detection.

  Replacing HEAD with a previously valid inventory hash will not fail
  under the current format, while rollback detection is explicitly deferred.
  Narrow this test to malformed/unknown HEAD values, or add an authenticated
  monotonic rollback check.


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/3am-on-call/output.json:14goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/3am-on-call/output.json:14-16]8;;

  Do not promise AEAD verification from the sealed plane.

  verify(gallery:) cannot decrypt the manifest or validate chunk AEAD tags
  without a DEK. Reframe this as shallow structural fsck, or make it an
  unlocked/deep verification operation.


────────────────────────────────────────────────────────────────────────
  minor [Stability & Availability]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/Sources/VaultCore/ChunkReader.swift:83Sources/VaultCore/ChunkReader.swift:83-90]8;;

  Guard offset + length against UInt64 overflow before the bounds check.

  offset is a public, caller-supplied UInt64. A large offset makes
  offset + UInt64(length) overflow and trap (crash) before the `
  🛡️ Overflow-safe bound

           let e = try entry(for: fileID)
  -        guard length > 0, offset + UInt64(length) <= e.unpaddedLength else {
  +        guard length > 0, offset <= e.unpaddedLength,
  +            UInt64(length) <= e.unpaddedLength - offset else {
               throw VaultError.rangeOutOfBounds
           }


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/manifest.json:2goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/manifest.json:2-4]8;;

  Align the manifest goal with the checked-in session path.

  goal points to goals/drafts/20260718-164118-private-photo-vault, but
  this session and its artifacts are under
  goals/CED-10-private-photo-vault. Consumers resolving this field will
  not find the goal or correctly identify the session source.


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/logistics/output.json:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/logistics/output.json:3-4]8;;

  Verify ImportDeclaration before using its hash for dedup.

  A caller-supplied plaintext BLAKE2b can be forged or stale. If it directly
  controls dedup or manifest aliasing, a genuine import can be mapped to
  attacker-selected metadata. Treat the declaration as an untrusted hint and
  bind it to a core-computed hash during a prehash or streaming verification
  pass.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-type-state/prompt.md:1goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-type-state/prompt.md:1]8;;

  Use repository-relative paths for the prompt inputs and output.

  The prompt points at /goals/drafts/20260718-164118-private-photo-vault,
  while the supplied artifacts live under
  goals/CED-10-private-photo-vault. This makes the generation step
  machine-specific and directs output away from the checked-in session.






  Also applies to: 7-7


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2]8;;

  Do not describe rename plus HEAD swap as one atomic commit.

  A directory rename and a HEAD-pointer update are separate filesystem
  operations. A crash between them, or before the required directory/HEAD
  fsyncs, can leave orphaned objects or a HEAD that is not durably backed by
  its manifest. Define ordering, commit markers, and recovery behavior for
  every crash point before claiming post-crash consistency.


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2]8;;

  Reconcile locked sync writes with the single-writer invariant.

  This design makes the gallery actor the only writer, but the two-plane
  design gives SealedVault.receiveChunk a no-session write path. If that
  API writes directly into the live CAS, it bypasses actor serialization,
  WAL coordination, and GC ordering. Route receives through actor-owned
  staging, or restrict sealed-plane writes to quarantine until an actor
  commit.


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2]8;;

  Keep the dedup index out of consumer-facing snapshots.

  Publishing the plaintext-BLAKE2b dedup index to grid, playback, and sync
  consumers exposes a linkability/confirmation surface. Keep it encrypted
  and internal, exposing only opaque file/chunk references or an explicitly
  authorized lookup API.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/prompt.md:1goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/prompt.md:1]8;;

  Use repository-relative paths for the prompt inputs and output.

  The prompt references /goals/drafts/20260718-164118-private-photo-vault,
  but the supplied session is under goals/CED-10-private-photo-vault. This
  prevents reliable replay and writes generated output to a machine-specific
  location.






  Also applies to: 7-7


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/output.json:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/output.json:3-4]8;;

  Qualify the compiler-only locking guarantee.

  Move-only consumption can enforce explicit lock(), but
  background/timeout invalidation still requires runtime revocation and
  stale-handle checks. State the guarantee as “explicit lock is move-only;
  lease expiry is runtime-enforced,” and ensure stale handles fail closed.


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-type-state/output.json:2goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-type-state/output.json:2]8;;

  Remove AEAD verification from the ciphertext-only types.

  LockedGallery and SyncView are described as requiring no unlock, yet
  they are granted AEAD-tag verification. Without the DEK this is
  impossible; silently reducing “verification” to hash/format checks would
  create false assurance. Keep tag verification behind UnlockSession.






  Also applies to: 8-8


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/logistics/output.json:15goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/logistics/output.json:15-16]8;;

  Keep corruption on a fail-closed error path.

  An AEAD failure must not look like a successful read that merely returns
  DamagedGoods; callers could ignore it and continue with invalid state.
  Use a typed thrown error or Result.failure carrying the RMA details, and
  make re-fetch a separate recovery action.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-two-plane/prompt.md:1goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-two-plane/prompt.md:1]8;;

  Use repository-relative paths for the prompt inputs and output.

  These paths point to the old
  /goals/drafts/20260718-164118-private-photo-vault tree instead of
  goals/CED-10-private-photo-vault, so replaying the prompt will resolve
  the wrong files and output location.






  Also applies to: 7-7


────────────────────────────────────────────────────────────────────────
  major [Stability & Availability]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-actor-snapshots/output.json:2]8;;

  Tie snapshot validity to storage retention.

  Content-addressed immutable manifests do not retain their transitive
  chunks. Once GC removes objects no longer reachable from HEAD, an old
  playback snapshot can fail mid-stream. Make opening a snapshot pin its
  manifest/chunks until release, or document historical snapshots as
  best-effort; the child idea is currently only a future rule.






  Also applies to: 8-8


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/competitor/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/competitor/prompt.md:3]8;;

  Use repository-relative paths for the prompt inputs and output.

  These paths point to the old
  /goals/drafts/20260718-164118-private-photo-vault worktree, while this
  session is checked in under goals/CED-10-private-photo-vault. Re-running
  the prompt will read or write the wrong, machine-specific tree.






  Also applies to: 9-9


────────────────────────────────────────────────────────────────────────
  major [Data Integrity & Integration]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-two-plane/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/deepen-two-plane/prompt.md:3]8;;

  Do not promise AEAD verification on the no-key plane.

  XChaCha20-Poly1305 tag verification requires the DEK. A locked vault can
  verify ciphertext-address hashes and structural format, while only an
  unlocked session can authenticate ciphertext with the AEAD key. Split
  these into shallow audit and deep authenticity verification.


────────────────────────────────────────────────────────────────────────
  major [Security & Privacy]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/output.json:11goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/regulator/output.json:11-12]8;;

  A returned AuditEvent is not an audit ledger.

  Callers can receive and discard the event, so this API does not guarantee
  a complete or durable record of unwrap, zeroization, or write operations.
  Use an owned append-only audit sink or explicitly describe these events as
  optional telemetry.


────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/logistics/prompt.md:3goals/CED-10-private-photo-vault/adhd/session-001-20260719-132924/logistics/prompt.md:3]8;;

  Use repository-relative paths for the prompt inputs and output.

  These paths point to the obsolete
  /goals/drafts/20260718-164118-private-photo-vault tree rather than
  goals/CED-10-private-photo-vault. Re-running the prompt will use the
  wrong inputs and write outside the current session.






  Also applies to: 9-9

Writing review comments... 5m 45s elapsed - still working - 32 findings so far

────────────────────────────────────────────────────────────────────────
  minor [Maintainability & Code Quality]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/Tests/VaultCoreTests/LockRaceTests.swift:106Tests/VaultCoreTests/LockRaceTests.swift:106-122]8;;

  Minor: allSatisfy can pass vacuously if no read completes.

  compactMap with try? drops every read that threw .vaultLocked, so if
  lock(drainDeadline:) drains before any of the 50 reads finish,
  outcomes is empty and outcomes.allSatisfy { $0 } is trivially true —
  the "completed reads must be correct" guarantee is then never actually
  exercised. Add a lower-bound assertion so the test fails if nothing
  completed.


  💚 Proposed guard

           let outcomes = await readTask.value
  +        #expect(!outcomes.isEmpty, "at least one read must complete before drain")
           #expect(outcomes.allSatisfy { $0 }, "completed reads must be correct")


────────────────────────────────────────────────────────────────────────
  major [Stability & Availability]
  → ]8;;vscode://file//Users/openclaw/src/divideby0/mobileseal/.worktrees/CED-10-private-photo-vault/Tests/VaultCoreTests/CompileFailTests.swift:111Tests/VaultCoreTests/CompileFailTests.swift:111-127]8;;

  Pipe deadlock ordering: drain output before waitUntilExit().

  process.waitUntilExit() is called before draining the pipe. If a fixture
  ever produces enough diagnostic output (e.g., a misuse triggering multiple
  errors/notes/fixits) to fill the OS pipe buffer, the child blocks on
  write() while the parent blocks on waitUntilExit() — a classic
  deadlock that would hang the whole test suite/CI run indefinitely. There's
  also no timeout to bound this.


  🔧 Proposed fix: read before waiting, add a bounded timeout

           try process.run()
  -        process.waitUntilExit()
           let data = pipe.fileHandleForReading.readDataToEndOfFile()
  +        process.waitUntilExit()
           return (process.terminationStatus, String(decoding: data, as: UTF8.self))

  Consider additionally guarding with a timeout (e.g., a watchdog
  DispatchWorkItem that terminates the process) so a hung swiftc
  invocation can't stall CI.


────────────────────────────────────────
Review complete
34 findings ✔

Major    20
Minor    14

81 files reviewed:
- .gitignore
- .swift-version
- CONTEXT.md
- Package.resolved
- Package.swift
- Sources/Argon2Bench/main.swift
- Sources/VaultCore/ChunkObject.swift
- Sources/VaultCore/ChunkReader.swift
- Sources/VaultCore/CryptoCore.swift
- Sources/VaultCore/Errors.swift
... and 71 more files
────────────────────────────────────────

Print all AI prompts: coderabbit review --show-prompts

REVIEW COMPLETE

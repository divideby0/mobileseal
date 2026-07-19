# Review wave-002

Blind multi-tool review wave for `CED-10-private-photo-vault`
(2026-07-19, diff base `main`, on the tree carrying the wave-001
fixes, commit `27bf0e7`).

**WAVE ABORTED (driver killed): this INDEX is hand-authored by the
executing session from the per-tool artifacts** — the `evie-agent
goals review` driver process was externally stopped mid-wave, so no
generated INDEX, completion detection, screen captures, or tab sweep
happened. Individual reviewers kept running in their tabs; their
on-disk outcomes:

| Tool        | Outcome                | Findings                               | Model     | Effort    | Detail                                                                                                                                                                                         |
| ----------- | ---------------------- | -------------------------------------- | --------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| claude-code | completed              | [FINDINGS.md](claude-code/FINDINGS.md) | opus      | high      | wrote REVIEW COMPLETE independently of the dead driver                                                                                                                                         |
| codex       | failed (never spawned) | none produced                          | (default) | (default) | root cause found post-wave: codex TUI blocked on a first-run TRUST prompt for this repo (never trusted in ~/.codex/config.toml), so every spawn "vanished"; trust recorded, fixed for wave-003 |
| sonarqube   | completed              | [FINDINGS.md](sonarqube/FINDINGS.md)   | (default) | (default) | 0 open issues (compute task pinned in FINDINGS.md)                                                                                                                                             |
| coderabbit  | completed              | [FINDINGS.md](coderabbit/FINDINGS.md)  | (default) | (default) | finished after the driver died; 4 findings (1 major)                                                                                                                                           |

Blindness caveat, recorded honestly: the draft `results/RESULT.md`
was accidentally swept into HEAD by a `git add -A` in the wave-001
fix commit (`27bf0e7`), so ALL wave-002 reviewers could read the
executor's narrative — a blindness-contract violation by the
executor, caught because a coderabbit minor cites the file.
claude-code's findings show no anchoring on it (its majors concern
code paths RESULT.md does not discuss). For wave-003 the draft is
removed from HEAD and the working tree for the wave's duration.

## Merged findings

Reconciled by the executing session, 2026-07-19. claude-code also
recorded a "verified, not findings" list (build/test/bench green from
a clean checkout, wave-001 fixes confirmed effective) — see its
FINDINGS.md.

### Fixed

1. **Drain force-zero revoked nothing: every read decrypted a DEK
   COPY** (claude-code #1, major — the one blocking finding) — the
   guarantee is now real: `CryptoCore.aeadOpen` gained a raw-key
   overload and ChunkReader/inventory reads decrypt against the
   custodian's OWN allocation (no copy), so zeroing mid-decrypt
   genuinely corrupts the tag and the straggler fails closed with
   `vaultLocked`. The copy-based `withDEK` shim is deleted; `KeyLease`
   copies remain only on SEALING paths (encryption — no plaintext
   revocation at stake) and are drain-awaited. This also resolves the
   efficiency nit #8 (no per-chunk `sodium_malloc`; nonce slice no
   longer copied through `Array`).
2. **`unpadded_length` unbounded → trapping overflow in chunk-count
   arithmetic** (claude-code #2) — bounded at 2^48 in `FormatV0`,
   validated in `parseBody`, documented in the entry table, hostile
   case added (`hostileUnpaddedLengthIsRejected`).
3. **`init(consumingAndZeroing:)` reinstated the ""≡"\0" collision**
   (claude-code #3) — empty input refused with `.emptyPassword`; the
   `max(count, 1)` padding is gone; regression test covers both
   initializers.
4. **Single-epoch code vs normative multi-epoch rule** (claude-code
   #4) — resolved the honest way for this leg: format v0 now PINS
   `keyring_count == 1` (parser rejects more, test added) and
   `docs/formats.md` states the trial-decryption rule as binding from
   the rotation leg onward. No trap left for rotation: a v0 reader
   can never meet a keyring it half-reads.
5. **Sealed-plane hashing could run before `sodium_init()`**
   (claude-code #5) — `SodiumRuntime.ensure()` is now the first
   statement of `SealedVault.init` and `create`.
6. **Import TOCTOU: dedup hash could describe bytes never stored**
   (claude-code #6) — pass 2 hashes the bytes it actually seals and
   the import throws typed `.sourceChangedDuringImport` on mismatch
   (also replaces the untyped length-change error).
7. **`.paddingInvalid`/`.lengthMismatch` never exercised**
   (claude-code #7) — direct unit tests pin the padding validator
   (conforming / non-zero pad byte / over-padded).
8. **Conformance test opens the committed fixture in place**
   (claude-code #9) — reference-implementation check now copies the
   fixture to a temp dir first.
9. **HEAD-repair write failure aborted a successful recovery**
   (coderabbit major) — the repair is now best-effort in full: a
   failed tmp write skips the repair instead of failing the unlock.
10. **wave-001 INDEX linked a codex FINDINGS.md that does not exist**
    (coderabbit) — replaced with "none produced (failed at launch)".
11. **RESULT.md Gate 9 said "PENDING AT WRITE TIME"** (coderabbit) —
    the draft result is being finalized with the full wave history as
    part of completion (and stays out of reviewer sight per the
    blindness caveat above).

### Rejected, with reasons

- **adhd prompt hard-coded paths** (coderabbit, repeat of wave-001) —
  immutable session provenance; not replayable by design. Same
  disposition as wave-001.

### Wave verdict

Aborted as a PROCESS (driver killed externally, codex absent) — so
wave-002 does NOT claim the gate. All its accepted findings are fixed
and regression-locked (`swift test`: 49 tests, 12 suites, green);
wave-003 runs the full four-reviewer wave on the fixed tree with the
codex trust issue resolved, and is the wave the gate stands on.

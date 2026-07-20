# Codex blind plan review — Manifest CRDT and Device Identity

## Blocking concerns

1. **Signatures are not domain-bound.** `GOAL.md §Workstream B.1` promises canonical encoding but does not require signatures to cover the gallery UUID, object kind, format/version, epoch, and every semantic field. Without explicit domain separators and gallery binding, valid entries, tombstones, trust lists, or HEAD descriptors can be replayed across galleries or interpreted as another object type.

2. **The proposed AddEntry cannot preserve the current storage contract.** `GOAL.md §Workstream B.1/B.4` omits `file_id`, `aad_file_id`, and the existing dedup hash, despite `docs/formats.md §Inventory object` requiring them and chunk decryption using `aad_file_id` in AAD. Re-authoring without preserving both IDs breaks dedup-shared chunks, thumbnail/Live-Photo parent links, reader lookup, and logical import identity; “byte-identical media” alone will not catch those failures.

3. **`target_entry_hash` has no normative meaning.** `GOAL.md §Workstream B.1/B.2` does not say whether it hashes the unsigned canonical payload, signed entry bytes, encrypted object, or logical `file_id`. It also lacks rules for tombstone-before-add delivery, multiple entries with identical content, malformed targets, and whether the gallery identifier participates in the target digest, so tombstone convergence and replay resistance cannot be implemented consistently.

4. **The TOFU trust root is circular and permits owner self-escalation.** `GOAL.md §Workstream A.2` says any device that can unlock may register its keys and role while the trust list is verified using signatures from keys contained in that same list. This also weakens the original `intake.md §9` premise of an authenticated `gallery_members` account: possession of a shared gallery password would be enough to self-register as owner and authorize deletion of everyone’s entries.

5. **The trust list has no convergent update model.** `GOAL.md §Workstream A.2/B.2` calls it “signed and versioned” but defines neither concurrent-update merge, signer authorization, revocation, fork resolution, nor rollback handling. The “retained but inert, later activated” rule is monotonic only if authority can grow forever; removing an owner under current-state validation could instead deactivate old tombstones and resurrect deleted content.

6. **The soft-delete state is internally contradictory and non-convergent.** `GOAL.md §Workstream C.2` calls it per-user state but stores it in a per-device structure, which means two devices for the same user can permanently disagree. No merge algebra is given for delete, restore, repeated delete, 30-day expiry, or restore-versus-expiry races, and one device can emit a permanent shared tombstone while another has already restored the item.

7. **The new on-disk manifest graph is unspecified, making WAL atomicity undefined.** `GOAL.md §Workstream B.3–B.5` never says whether `manifest/{hash}` contains individual operations, complete encrypted sets, or a signed snapshot/frontier, nor what address HEAD commits. The existing `docs/formats.md §Commit protocol/Recovery` depends on HEAD naming one complete encrypted inventory and recovery choosing the highest generation; “no clocks” leaves no equivalent recovery rule for missing or dangling HEAD.

8. **Independent migration of backed-up v0 copies produces unresolved identity conflicts.** `GOAL.md §Workstream B.4` has each device re-sign the same legacy entries as “THIS device,” so two devices restoring and migrating the same v0 vault will create different signed AddEntries for the same historical `file_id`. If identity is entry hash they become duplicates; if identity is `file_id`, set union produces conflicting authors and signatures without a winner or equivalence rule.

9. **Migration is not atomic across all state it creates.** `GOAL.md §Workstream A/B.4/B.5` requires a Keychain identity, trust-list genesis, manifest, signed HEAD, rollback high-water mark, and possibly delete-state sidecar, but the current gallery WAL can atomically commit only filesystem objects plus HEAD. The plan needs an idempotent creation order and recovery state machine for crashes between Keychain insertion, trust anchoring, and HEAD publication; its crash-injection gate currently mentions only the v0-to-manifest commit.

10. **The rollback detector both overclaims and conflicts with backup restoration.** `GOAL.md §Workstream B.5` does not define who signs HEAD, whether high-water marks are keyed by every observed signer, or where the marks live; a mark inside the backed-up vault rolls back with it, while a surviving device-bound mark rejects a legitimate older iCloud restore. A per-device counter detects only replay of an older HEAD from a known signer, not omission of CRDT elements, replay from another trusted signer, or a signer producing a higher counter over an older root.

11. **“Keychain / Secure Enclave” is not a realizable custody design as written.** `GOAL.md §Workstream A.1` and `§Green gates 4` conflate generic Keychain storage with Secure Enclave operations: the selected Ed25519/X25519 private keys cannot simply be created as non-exportable Secure Enclave `SecKey` keys usable by libsodium. Storing them as Keychain data normally returns raw `Data`, contradicting the compile-fail “never raw Data” gate unless the plan specifies an enclave-backed wrapping construction and an unavoidable, bounded extraction path into `SecureBytes`.

12. **Device migration can strand the restored vault behind its old owner identity.** `GOAL.md §Workstream A.1/A.2` selects `WhenUnlockedThisDeviceOnly`, while `wayfinder/MAP.md §Decisions` confirms the vault itself participates in backup. On a replacement device the vault and old signed trust list can restore without the old private key; the plan gives no authorized way for the new identity to regain owner status without either the lost owner signature or insecure password-based self-promotion.

13. **Deletion semantics do not cover the app’s entry graph.** `GOAL.md §Workstream C.1/C.2` treats an item as one entry, but `MediaMetadata` and `MediaIndex` model an original, thumbnail, Live Photo video, and poster as separately addressable linked entries. The plan must define whether soft/hard deletion targets the whole media aggregate, how Recently Deleted retains previews, and whether purge tombstones descendants; otherwise it creates visible orphans or leaves deleted media reachable.

14. **The gates do not exercise the claimed durable contract.** `GOAL.md §Green gates` lacks two-independent-peer histories, concurrent trust-list updates, per-user soft-delete merging, restore-versus-expiry, backup restore, lost Keychain identity, duplicate migration, and deletion of linked media. The scripted e2e checks only migration plus unchanged playback, despite pager delete, grid multi-select, Recently Deleted, restore, purge, and relaunch durability all being explicit deliverables.

## Advisories

1. **Canonical encoding needs parser-level canonicality, not merely fixed endianness.** `GOAL.md §Workstream B.1/Green gate 3` should require canonical ordering of sets and maps, rejection of duplicates and alternate encodings, declared bounds for every list/blob, and hash computation over exactly one accepted representation. Otherwise two conforming peers may verify signatures but compute different entry or manifest hashes.

2. **The cryptographic layers are ambiguously ordered.** `GOAL.md §Workstream B.1` names `encrypted_metadata` while the current metadata is opaque plaintext inside an AEAD-encrypted inventory. The format must say what is encrypted, with which nonce and AAD, whether signatures cover plaintext or ciphertext, and whether verification occurs before or after gallery unlock.

3. **The signature tamper gate is too coarse.** `GOAL.md §Green gate 1` says flipping any byte must produce a typed failure, but an outer AEAD or structural parser may reject the object before signature verification is reached. Separate KATs should prove canonical signing bytes, deterministic public-key verification, wrong-gallery rejection, wrong-object-domain rejection, and signature failure independently of encryption failure.

4. **The migration performance condition is unmeasurable.** `GOAL.md §Workstream C.1` says to show progress only if migration “measurably lags at personal-library scale,” but defines neither library size, hardware profile, latency threshold, memory ceiling, nor cancellation policy. The three-entry KAT fixture cannot support that UI decision.

5. **X25519 custody expands the highest-risk surface without a consumer in this leg.** `GOAL.md §Workstream A.1` generates and persists a future sealed-box key even though sealed-box sharing is explicitly deferred. If it remains in scope, its independent lifecycle, key identifier, corruption handling, and rotation behavior need gates equivalent to the signing key rather than being treated as incidental.

6. **The zero-HITL claim conflicts with the map’s custody caveat.** `GOAL.md §Executor notes` says every gate runs on macOS or simulator, while `wayfinder/MAP.md §Notes` says executor shells cannot validate the login Keychain. Simulator tests can validate API behavior and attributes, but they cannot substantiate the full device-bound/Secure-Enclave custody claim; the residual must be stated instead of counted green.

## Questions the plan leaves unanswered

1. **What exactly is the trust-list genesis object?** `GOAL.md §Workstream A.2` does not identify its signer, authenticated gallery binding, initial owner-key commitment, or how a verifier distinguishes legitimate genesis from an attacker-created self-signed owner list.

2. **What is the durable identity of an AddEntry?** `GOAL.md §Workstream B.1/B.4` leaves unclear whether identity is preserved `file_id`, a canonical operation hash, content hash, or some migration-derived identifier. That choice determines dedup behavior, tombstone targeting, linked metadata, and conflict handling.

3. **What principal makes soft deletion “per-user” before accounts exist?** `GOAL.md §Workstream C.2` has only device identities and explicitly defers membership machinery. It does not define a stable user identifier, encryption key, namespace, or authorization model by which several devices later merge the same user’s delete state without exposing it to collaborators.

4. **What is the supported recovery flow after a legitimate backup restore?** `GOAL.md §Workstream B.5` supplies only `rolledBackManifest`, with no reset, re-attestation, new-device enrollment, or user-visible recovery state. Failing loud is not a complete behavior when restoring the backed-up vault is an intentional supported path.

5. **What local revision replaces inventory generation for app snapshots?** `GOAL.md §Workstream B.3/C.1` says no clocks, but `Gallery.snapshotStream`, `InventorySnapshot.generation`, fresh readers, playback caches, and the coordinator all rely on a per-commit revision boundary. A non-CRDT local revision is possible, but its persistence and behavior after merge, migration, and recovery are not specified.

6. **What does purge do when the current device lacks tombstone authority?** `GOAL.md §Workstream C.2` mandates that expiry emits a hard tombstone, while the same section requires author-or-owner authorization. The plan does not say whether a member’s expired item remains locally hidden, produces a retained inert tombstone, reports failure, or waits for an authorized device.

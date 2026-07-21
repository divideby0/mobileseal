# Codex blind plan review — Multiple Galleries

## Blocking concerns

1. `GOAL.md §Workstream A.2` never selects the lifecycle architecture left open by `references/intake.md` (“N coordinators or a coordinator-per-unlocked-gallery”). The existing `MobileSealApp.swift §MobileSealApp` owns exactly one store, while scene events, idle tasks, switch taps, and unlock tasks can race unless one process-wide actor serializes every select/lock/unlock transition. Per-path serialization in `VaultProcessRegistry.swift` cannot enforce the cross-path one-unlocked policy.

2. `GOAL.md §Workstream A.2` says switching consumes the previous coordinator’s `lock()`, but that is not the app’s complete custody path. `VaultStore.swift §intents` first clears plaintext-adjacent state and purges `ThumbnailPipeline`; only then does `VaultCoordinator.swift §Lock` sweep playback and drain the session. Calling the coordinator directly can leave decoded thumbnails, import summaries, and other old-store residue alive while the target unlocks.

3. `GOAL.md §Green gates 3` proposes “registry shows ≤1 claim” as proof of one live DEK, but claims are acquired only by `UnlockSession.openGallery()` after `SealedVault.unlock()` has already created a live custodian. `VaultProcessRegistry.swift` intentionally permits simultaneous claims for different canonical paths, so neither its count nor its per-path mutex proves the app invariant. The gate needs to show the old key zeroed and escaped readers revoked before target unlock/KDF custody begins, including double-switch and background races.

4. `GOAL.md §References` treats `SealedVault` construction as a harmless metadata read for the locked list. `SealedVault.swift §init(directory:)` first runs `Recovery.recover`, which mutates WAL/HEAD state, and it does so without consulting the writer claim. Refreshing the switcher while one gallery is open could therefore run recovery against its live writer unless the plan mandates cached discovery, skips the active path, or adds a genuinely read-only metadata parser.

5. `GOAL.md §Workstream A.3` incorrectly says the affected state is already per-gallery in core. Auto-lock uses two global keys in `LockPreferences.swift`; the calibration report is one `Vault/calibration.json`; Recently Deleted is already app-scoped by `galleryID`; rollback marks share one file internally keyed by gallery and signer; only trust is embedded per gallery. The plan needs an exact key/path ownership table and migration for global preferences and calibration records, rather than a blanket “stop hardcoding paths.”

6. A coordinator-per-gallery implementation would construct multiple `FileRollbackStateStore` instances over the same `DeviceLocal/rollback-state.json`; each instance has its own `NSLock`, so concurrent unlocks can perform unsynchronized read-modify-writes and lose another gallery’s observations. `GOAL.md §Workstream A.3` does not require a shared store instance, file-wide synchronization, or strict global unlock serialization. That omission directly threatens the rollback detector CED-13 made fail-closed.

7. `GOAL.md §Workstream B.3` does not define what the “registry” persists, how entry #1 is identified, or how migration is atomic and idempotent. `AppContainer.swift §Gallery discovery` gives the directory a random UUID-like basename, while `SealedVault.create` independently mints the authoritative `gallery.meta` UUID; those identifiers are not interchangeable. Partial creation, malformed directories, duplicate copied gallery IDs, migration interruption, and preservation of existing settings/calibration are all absent from the migration gate.

8. `GOAL.md §Executor notes` says the label store mirrors `KeychainDeviceKeyStore` while its ciphertext “rides device backup.” That existing key is `WhenUnlockedThisDeviceOnly` and deliberately absent from backups, so restored label ciphertext would arrive without its decryption key; choosing a backup-capable or synchronizable key would instead violate the stated device-only model. The plan must specify a distinct key item, accessibility class, missing-key recovery, backup outcome, AEAD format, gallery-ID AAD binding, and tamper behavior.

9. `GOAL.md §Workstream B.2` does not define the cover’s plaintext lifecycle. Existing thumbnail decoding produces ordinary-heap `Data`/`UIImage`, and pre-unlock rendering necessarily keeps decrypted cover pixels in memory; “container scan finds no plaintext covers” tests only part of that boundary. The plan needs a no-plaintext-file pipeline, crash/interruption behavior, temporary-directory audit scope, memory-residency disclosure, and explicit purge/shield rules.

10. `GOAL.md §Green gates` lacks adversarial gates for the new failure surfaces: rapid A→B→C switching, scene background during target KDF, switching during import/playback/snapshot delivery, registry creation crash points, corrupt or swapped label records, missing Keychain keys after restore, duplicate gallery IDs, and reset/relaunch isolation. The single happy-path e2e cannot establish the lifecycle, migration, or custody claims made by the goal.

## Advisories

11. `GOAL.md §Workstream B.1–B.2` overstates what the sealed plane can honestly display. `GalleryMeta` exposes only gallery UUID, KDF parameters, salt/keyring structure, and epochs; `headState()` adds structural pointer status, not media counts, names, covers, or a trustworthy creation date. Any “created-date” must be identified as registry metadata or unstable filesystem metadata with defined copy/restore semantics.

12. `GOAL.md §Workstream B.2` calls color/emoji part of a “generic” unlabeled tile, but either value is another user-assigned device-local label requiring the same encrypted schema, migration, and leakage treatment. It is not covered by the settled name-and-cover decision and should be removed or explicitly scoped.

13. `GOAL.md §Green gates 1 and 3` combines “VaultCore untouched or additive-only” with registry instrumentation without saying where the observable lives. Production exposure of the private writer set would widen a security primitive merely for testing. The plan should constrain any claim/key counters to internal or DEBUG-only probes and test externally observable revocation wherever possible.

14. `wayfinder/MAP.md §Not yet specified` says the GC/repair leg is sharpened by tombstones “THIS leg creates.” Multiple Galleries creates no tombstones; CED-13 already did. This stale statement can misdirect the executor into unrelated format or deletion work.

## Questions the plan leaves unanswered

15. After the old gallery is drained and the target password is wrong, does the UI remain on the gallery list, stay on the target’s unlock screen, or require explicitly selecting the old gallery and re-entering its password? `GOAL.md §Green gates 2` says only “fails clean,” which does not define the resulting lifecycle state.

16. What owns the 0/1/N-gallery navigation state and the single serialized switch transaction? `GOAL.md §Workstream B.1` makes the list root only when more than one gallery exists but never identifies where a one-gallery user invokes creation of gallery #2.

17. Is registry identity the parsed `gallery.meta.galleryID`, the canonical directory path, or both? The answer determines label lookup, per-gallery UserDefaults keys, duplicate-copy handling, ordering, and whether moved/restored directories retain their device-local metadata.

18. Which gallery’s auto-lock policy governs a target that is unlocking, and what policy applies while only the locked list is visible? The existing `VaultStore` owns both the preference and scene timestamps, so switching stores without a defined handoff can apply the old gallery’s policy to the new session.

19. Does the cover’s explicit pre-unlock leak also authorize appearance in the iOS app-switcher snapshot? `MobileSealApp.swift` currently raises an opaque shield on `.inactive`; the plan does not say whether the new list remains behind that global shield or bypasses it.

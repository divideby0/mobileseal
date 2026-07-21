The change implements most of the requested manifest, migration, rollback, and delete surfaces, but it is not ready to merge: the advertised device-key custody gate is bypassable, and five major correctness/format issues can make valid deletes no-op, write manifests that cannot be reopened, violate the signed-format contract, create a self-inconsistent recovered HEAD, or silently lose Recently Deleted state. `git diff --check` was clean; I could not independently run `swift test` or the generic Xcode build because this review sandbox prevented SwiftPM/Xcode from writing their user cache and applying their nested sandbox, so the findings below are based on direct code and test inspection rather than a successful local gate run.

| # | Severity | Location | Finding |
|---|---|---|---|
| 1 | blocker | `Sources/VaultCore/DeviceIdentity.swift:68`; `App/MobileSeal/Support/KeychainDeviceKeyStore.swift:67` | The raw device-key API bypasses the compile-fail custody gate, and the Keychain intermediaries are not reliably zeroed. |
| 2 | major | `Sources/VaultCore/Gallery.swift:348` | Any inert tombstone makes a later valid delete incorrectly return as a no-op. |
| 3 | major | `Sources/VaultCore/TrustList.swift:59` | Trust-list writers do not enforce the bounds that their parser requires, so public device names or the 1025th registration can commit an unreadable vault. |
| 4 | major | `Sources/VaultCore/FormatConstantsV1.swift:43` | The v1 signature preamble omits the gallery epoch required by the goal for every signed object. |
| 5 | major | `Sources/VaultCore/SealedVault.swift:430` | Recovery can install a HEAD signed by a device that the recovered manifest does not trust, causing the next ordinary unlock to reject the repaired vault. |
| 6 | major | `App/MobileSeal/Support/RecentlyDeletedStore.swift:47`; `App/MobileSeal/VaultCoordinator.swift:463` | Recently Deleted persistence is fail-open, and manual purge deletes its ledger row before the hard-delete commit succeeds. |

## 1. The raw-key custody gate is bypassable and does not wipe all intermediaries

Evidence: `DeviceIdentity.generateSecretKey()` is public at `Sources/VaultCore/DeviceIdentity.swift:68`, and it returns the general-purpose `SecureBytes` whose public `withUnsafeBytes` method is at `Sources/VaultCore/SecureBytes.swift:109`. A `DeviceKeyStore` outside the audited file can therefore generate the real identity key, copy it into `Data` or `[UInt8]`, and then construct the returned `DeviceIdentity`; the new compile-fail fixture only attempts to read the private `identity.secretKey`, so it does not exercise this supported escape route. In the reference store's load path (`App/MobileSeal/Support/KeychainDeviceKeyStore.swift:63-73`), wiping `bytes` leaves both the `result` CF object and the bridged `data` holding the Keychain result until scope exit. In the create path (`:91-99`), `attributes` retains a `Data` value before the deferred mutation of `keyData`; Swift `Data` copy-on-write/bridging means wiping that binding does not guarantee that the buffer retained by the dictionary is the one being wiped.

This matters because the goal and green gate explicitly require one audited raw-key transfer point and a compile-fail gate everywhere else. An escaped Ed25519 secret can forge AddEntry, Tombstone, TrustList, and HEAD signatures indefinitely; merely deallocating app-owned `Data` without wiping it does not meet the stated custody contract.

Suggested fix: move device-secret generation/import and the Apple Keychain adapter behind a package-internal boundary (for example, a package target with package-only raw material APIs) so normal VaultCore clients can only receive a `DeviceIdentity`, then add a negative fixture that attempts the actual `generateSecretKey().withUnsafeBytes` route. In the adapter, use a uniquely owned mutable buffer, clear every app-owned reference/container that aliases it, wipe that exact buffer before release, and likewise make the Keychain load result uniquely mutable and wipe it after copying into guarded memory.

## 2. Inert tombstones block a later valid deletion

Evidence: `ManifestState.effectiveView` explicitly retains untrusted or digest-mismatched tombstones as inert at `Sources/VaultCore/SignedManifest.swift:242-264`. However, `Gallery.deleteEntries` builds `alreadyTombstoned` from every tombstone's target ID at `Sources/VaultCore/Gallery.swift:348-351`, without applying those validity rules. If a visible entry has an untrusted tombstone or a mismatched-digest tombstone, a legitimate delete by the current trusted device produces no new tombstone and returns at line 358, leaving the entry visible.

This matters because inert tombstones are a required, normal CRDT state (including after merge), not parse failures. They must be retained and reported but must not prevent a valid delete-for-everyone. In the app, manual purge can consequently remove the soft-delete row while `deleteEntries` reports success without suppressing anything, making the supposedly purged item reappear.

Suggested fix: only treat a target as already deleted when at least one tombstone actually passes the same trust/target/digest checks against the current representative, or simply mint the current device's canonical tombstone whenever the target remains in the effective view. Add tests for both an untrusted tombstone and a trusted wrong-digest tombstone followed by `deleteEntries`.

## 3. Trust-list writers can emit data their parser rejects

Evidence: `SignedTrustList.payloadBytes` converts every device-name UTF-8 length directly to `UInt16` at `Sources/VaultCore/TrustList.swift:69-71`, while `minted` at lines 83-99 validates only duplicate keys and signer membership. It does not enforce `maxDeviceNameBytes` or `maxTrustedDevices`. The parser does enforce the 256-byte name limit at `Sources/VaultCore/TrustList.swift:126-129` and the 1024-device limit at lines 112-116. Public `SealedVault.create`/`unlock` accept an arbitrary `deviceName`, and TOFU registration can also grow an already-valid 1024-device list to 1025.

This matters because a 257-byte UTF-8 name is signed and committed successfully but makes the manifest fail on the next open; a name exceeding `UInt16.max` traps during serialization. Likewise, the 1025th registration creates a manifest that cannot be parsed again. A user-controlled iOS device name can therefore make creation or enrollment leave the vault unusable.

Suggested fix: validate all writer-side bounds before signing or committing and return a typed error (or apply a documented deterministic UTF-8-safe truncation for display names). Make `SignedTrustList.minted` throwing, enforce device count, name byte length, roles, and signer membership there, and add round-trip tests at 256/257 bytes and 1024/1025 devices.

## 4. Signed objects are not bound to the gallery epoch

Evidence: the goal requires every AddEntry, Tombstone, TrustList, and HEAD descriptor signature to cover the epoch (`GOAL.md:67-75`). `FormatV1.signingBytes` at `Sources/VaultCore/FormatConstantsV1.swift:43-49` signs only domain, version, gallery UUID, and payload. AddEntry happens to carry its chunk epoch in its payload, but Tombstone, TrustList, and HEAD payloads carry no gallery sealing epoch (for example, the HEAD payload at `Sources/VaultCore/ManifestObject.swift:151-158`). The implementation documentation weakens the requirement to "epoch included where present" at `docs/formats.md:322-325` instead of implementing the goal.

This matters because AEAD AAD binding is not a signature binding: anyone authorized to open and reseal an old object at another epoch can preserve signatures that the specified protocol requires to become invalid. Although the current keyring is pinned to epoch 0, the persisted v1 encoding and KATs are being established now; fixing this only when multi-epoch support arrives would require a format/signature compatibility change.

Suggested fix: include the gallery epoch in the common signing preamble and thread it through mint/verify for every signed kind, then regenerate the KATs and add wrong-epoch signature probes for Tombstone, TrustList, and HEAD as well as AddEntry.

## 5. Recovery can write a HEAD whose signer is absent from the manifest trust list

Evidence: for a missing/corrupt/dangling HEAD, the v1 recovery scan signs a fresh descriptor with the current `identity` and installs it at `Sources/VaultCore/SealedVault.swift:430-461`, without checking whether that identity appears in the recovered manifest's trust list. On the next normal v1 open, the code explicitly rejects exactly that state at `Sources/VaultCore/SealedVault.swift:370-375`.

This matters for the specified restore behavior: on a replacement device (fresh Keychain identity) recovering a vault with a damaged HEAD, the first unlock can return the recovered manifest but persist a HEAD that the next unlock rejects as `.untrustedSigner(.head)`. The app's best-effort `ensureDeviceRegistered()` usually papers over this with a second commit, but its error is swallowed; a read-only SDK client, a lock before registration, or an I/O failure during registration leaves the repaired vault unable to unlock normally.

Suggested fix: do not publish a repaired HEAD signed by an unlisted device. Either defer HEAD repair until the TOFU registration commit, or atomically union/register the current device into a new recovered manifest and commit that manifest together with its HEAD. Add a test using a fresh identity, a removed HEAD, recovery followed by lock without explicit registration, and a second unlock.

## 6. Recently Deleted state is silently discarded before durable success

Evidence: `RecentlyDeletedStore.load` treats every read or decode failure as an empty ledger and `save` discards every encoding/write error at `App/MobileSeal/Support/RecentlyDeletedStore.swift:47-60`. Separately, manual purge calls `store.remove` before `gallery.deleteEntries` at `App/MobileSeal/VaultCoordinator.swift:460-467`; on any commit error it only logs and breaks, after the only retry record has already been removed.

This matters because the goal explicitly requires soft-delete, restore, purge, and relaunch state to be durable. A corrupt ledger silently resurrects every soft-deleted item and can be overwritten as an empty/new ledger. A disk, lock, or commit failure during manual purge similarly makes an item reappear in the normal grid even though the user selected permanent removal, with no UI error and no retained row to retry.

Suggested fix: make ledger load/save operations throwing, distinguish a missing file from I/O or decode corruption, and surface failures through the coordinator/UI. For purge, read the row without removing it, commit all aggregate tombstones first, and delete the ledger row only after success (or restore the exact row on failure). Add injected corrupt-ledger, write-failure, and hard-delete-failure tests.

REVIEW COMPLETE

Manifest CRDT & Device Identity — fourth executed leg of the
private-photo-vault wayfinder map, drafted after CED-12 merged.

Map ticket: Ed25519/X25519 device keys, signed AddEntry/Tombstone,
set-union merge, trust-on-first-use; supersedes CED-10's local
encrypted inventory format-v0 with the durable signed-entry format
(version field makes the migration detectable); owns rollback
detection (deferred from CED-10's Codex plan review Q6).

Spec grounding (full v0.1 spec §5.4 device identity, §9 manifest/CRDT
model): one Ed25519 signing + one X25519 sealed-box keypair per
device, generated on first launch, never synced (Signal-style
multi-device); public keys eventually registered server-side (cloud
legs). Manifest entries: AddEntry {content_hash, chunk_list,
encrypted_metadata, author_device_pubkey, signature}; Tombstone
{target_entry_hash, author, signature}; validity rule checked
client-side: a tombstone is honored only if its author matches the
original entry's author or an owner-role device. Merge = set union,
no clocks; display order from EXIF dates. TOFU confirmed (session-001
Q8). Epoch field already reserved in gallery.meta keyring.

Standing constraints: formats are the cross-platform contract —
manifest/entry/tombstone wire formats land in docs/formats.md with
KAT vectors (CED-10 pattern); VaultCore stays UIKit-free; this leg is
zero-HITL (pure swift test + app adoption of the new manifest,
simulator-testable); background-sealed-transfer-only principle
unaffected (signing happens in the open app).

Open for grilling: device-key custody at rest on iOS (spec §5.4 says
passphrase-wrapped; the app has gallery passwords, not a device
passphrase — Keychain/Secure-Enclave protection is the candidate;
the CLI leg later needs a portable passphrase-wrapped file variant,
so custody must be pluggable); whether delete/tombstone UI ships this
leg or stays core-only; rollback-detection mechanism shape.

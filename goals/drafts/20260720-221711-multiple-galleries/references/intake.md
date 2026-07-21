Multiple Galleries — fifth executed leg of the private-photo-vault
wayfinder map, drafted after CED-13 merged. The "multiple private
vaults" half of the product promise, and the last frontier ticket
before Local Peer Sync unblocks.

Map ticket: per-gallery DEK/password, gallery switcher, per-gallery
lock state (VaultCore's process-wide writer registry already keys by
vault path).

Ground truth: VaultCore has always been multi-gallery-capable
(gallery = directory; independent keyring/DEK per gallery; the
process registry serializes writers per path). The app layer is the
single-gallery part: one AppContainer path, one VaultCoordinator, one
unlock flow. This leg is mostly app architecture: a gallery registry
(create/list), N coordinators or a coordinator-per-unlocked-gallery
model, switcher UI, per-gallery Settings (auto-lock prefs are
currently global), per-gallery device enrollment (trust list is
per-gallery — CED-13), per-gallery Recently Deleted stores.

Standing decisions that bear: spec goal "multiple galleries, each
with its own password" (independently keyed — CED-10 keyrings);
calibrate-at-creation per gallery (each new gallery calibrates KDF
params); backup inclusion applies per gallery; lock-on-background
applies to ALL unlocked galleries.

Open for grilling: what a LOCKED gallery list shows (names would leak
content hints on the pre-unlock screen — names could live inside the
encrypted metadata instead, showing generic tiles until unlocked);
whether multiple galleries can be unlocked simultaneously (memory
cost: each unlocked DEK + caches; switcher UX) or switching locks the
previous; cross-gallery move/copy scope (needs re-encryption under
the target DEK — this leg or deferred).

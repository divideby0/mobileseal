import Foundation
import VaultCore

/// The app-container contract (GOAL WS A.3, Codex B8).
///
/// Layout under the app's Application Support directory:
///
///     Application Support/
///       Vault/                      ← "vault root": ciphertext only,
///         galleries/{uuid}/         ← one VaultCore gallery directory
///       Staging/                    ← plaintext picker material, transient
///
/// Contract:
///  - Vault root files carry iOS Data Protection `.completeUnlessOpen`
///    (writable during background import completion) and PARTICIPATE
///    in iCloud/device backup — ciphertext is safe to back up and is
///    the only pre-sync path that survives device migration. Gate 4
///    asserts nothing under the vault root is `isExcludedFromBackup`.
///  - Staging holds the only plaintext ever written to disk by the
///    app: provider copy-ins live there between "staged" and
///    "imported", are removed at import end (success, failure, or
///    cancellation), and the WHOLE directory is wiped on every launch
///    so a crash mid-import cannot strand plaintext (gate 4's crash
///    path). Staging is excluded from backup.
struct AppContainer: Sendable {
    let vaultRoot: URL
    let galleriesDir: URL
    let stagingDir: URL

    /// Standard container in Application Support.
    static func standard() throws -> AppContainer {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try AppContainer(base: base)
    }

    /// Seam for tests: any base directory works (unit tests use temp
    /// dirs so parallel tests never share state).
    init(base: URL) throws {
        vaultRoot = base.appendingPathComponent("Vault", isDirectory: true)
        galleriesDir = vaultRoot.appendingPathComponent("galleries", isDirectory: true)
        stagingDir = base.appendingPathComponent("Staging", isDirectory: true)
        try prepare()
    }

    private func prepare() throws {
        let fm = FileManager.default
        for dir in [vaultRoot, galleriesDir, stagingDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        Self.applyProtection(.completeUnlessOpen, to: vaultRoot)
        Self.applyProtection(.completeUnlessOpen, to: stagingDir)
        // Vault root participates in backup (grill Q7): assert the
        // exclusion flag is NOT set rather than setting anything.
        // Staging is transient plaintext workspace — never back it up.
        var staging = stagingDir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? staging.setResourceValues(values)
    }

    /// Directory-level Data Protection: files created inside inherit
    /// the class. Best-effort on simulator (attribute accepted but not
    /// enforced) and a no-op on non-iOS platforms — the residual gap
    /// is a documented device-only check (Codex A7).
    static func applyProtection(_ type: FileProtectionType, to url: URL) {
        #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: type], ofItemAtPath: url.path)
        #endif
    }

    // MARK: - Gallery discovery

    /// The single gallery this leg manages (Multiple Galleries is the
    /// next map ticket). Discovery = first directory under galleries/
    /// containing a gallery.meta.
    func existingGalleryDirectory() -> URL? {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: galleriesDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return nil }
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first { fm.fileExists(atPath: $0.appendingPathComponent("gallery.meta").path) }
    }

    /// Mints the directory for a new gallery (name = fresh UUID; the
    /// galleries/{id} container convention from CONTEXT.md).
    func newGalleryDirectory() -> URL {
        galleriesDir.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    }

    // MARK: - Staging lifecycle

    /// Wipes everything under Staging/. Called on every launch and at
    /// import end — the crash-path half of the custody claim.
    func wipeStaging() {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: stagingDir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    /// A fresh per-batch staging subdirectory.
    func makeBatchStagingDirectory() throws -> URL {
        let dir = stagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyProtection(.completeUnlessOpen, to: dir)
        return dir
    }
}

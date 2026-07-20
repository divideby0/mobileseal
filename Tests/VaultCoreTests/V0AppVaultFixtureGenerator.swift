import Foundation
import Testing

@testable import VaultCore

/// Generates the committed PRE-MIGRATION app vault fixture
/// (`App/Fixtures/v0-vault/`): a format-v0 gallery holding three real
/// fixture images (each with a linked thumbnail entry carrying the
/// app's MediaMetadata JSON), which the scripted e2e (gate 2) seeds
/// into the app container and migrates transparently at unlock.
///
/// Run manually: `VAULTCORE_REGEN_V0_APP_FIXTURE=1 swift test`.
@Suite struct V0AppVaultFixtureGenerator {
    static let password = "e2e-migration-password"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VaultCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["VAULTCORE_REGEN_V0_APP_FIXTURE"] == "1"))
    func regenerate() throws {
        let fixturesDir = repoRoot.appendingPathComponent("App/Fixtures")
        let outDir = fixturesDir.appendingPathComponent("v0-vault")
        let vaultDir = outDir.appendingPathComponent("gallery")
        let fm = FileManager.default
        try? fm.removeItem(at: outDir)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        var pwBytes = Array(Self.password.utf8)
        let pw = try SecureBytes(consumingAndZeroing: &pwBytes)
        // Floor KDF params: the e2e unlock should not pay production
        // Argon2id cost. Within documented bounds; the app reads the
        // parameters from gallery.meta like any vault.
        _ = try SealedVault.createV0(
            at: vaultDir, password: pw,
            kdfParams: KDFParams(opslimit: 1, memlimit: 16 << 20))

        // ISO8601 dates the app's MediaMetadata decoder accepts.
        func metaJSON(_ fields: [String: String], v: Int = 2) -> [UInt8] {
            var parts = ["\"v\":\(v)"]
            for key in fields.keys.sorted() {
                parts.append("\"\(key)\":\"\(fields[key]!)\"")
            }
            return Array("{\(parts.joined(separator: ","))}".utf8)
        }

        var manifestLines: [String] = []
        for (i, name) in ["fixture-0000.jpg", "fixture-0002.jpg", "fixture-0004.jpg"]
            .enumerated()
        {
            let media = [UInt8](
                try Data(contentsOf: fixturesDir.appendingPathComponent(name)))
            let originalID = try seedV0Entry(
                directory: vaultDir, password: Self.password, media: media,
                metadata: metaJSON([
                    "kind": "original",
                    "filename": name,
                    "uti": "public.jpeg",
                    "importedAt": "2026-07-0\(i + 1)T12:00:00Z",
                    "dateTaken": "2026-06-0\(i + 1)T12:00:00Z",
                ]))
            // Thumbnail: the same (small) image bytes, linked to the
            // original — the aggregate the delete tiers operate on.
            _ = try seedV0Entry(
                directory: vaultDir, password: Self.password,
                media: media,
                metadata: metaJSON([
                    "kind": "thumbnail",
                    "parent": originalID.description,
                    "uti": "public.jpeg",
                    "importedAt": "2026-07-0\(i + 1)T12:00:00Z",
                ]))
            manifestLines.append("\(name) \(originalID.description)")
        }
        // The unlock throttle sidecar is runtime state, not fixture.
        try? fm.removeItem(at: vaultDir.appendingPathComponent("unlock.throttle"))
        try manifestLines.joined(separator: "\n")
            .write(
                to: outDir.appendingPathComponent("expected.txt"),
                atomically: true, encoding: .utf8)
    }

    /// The committed fixture must stay v0 and unlockable — regression
    /// pin so a later regeneration cannot silently commit a migrated
    /// (v1) fixture, which would gut the e2e's migration leg.
    @Test func committedFixtureIsPreMigration() throws {
        let vaultDir = repoRoot.appendingPathComponent("App/Fixtures/v0-vault/gallery")
        guard FileManager.default.fileExists(atPath: vaultDir.path) else {
            Issue.record("v0-vault fixture missing — run the generator")
            return
        }
        let head = [UInt8](
            try Data(contentsOf: vaultDir.appendingPathComponent("HEAD")))
        guard case .v0 = try HeadFile.parse(head) else {
            Issue.record("v0-vault fixture is not format v0")
            return
        }
    }
}

import Foundation

/// Launch-argument seams for the scripted e2e gate (gate 2) — the UI
/// tests drive the REAL app through the REAL pipeline; only the
/// picker is replaced by the fixture seam (the system picker gets a
/// manual device smoke test instead).
enum UITestSupport {
    /// Present → the gallery view shows a hidden "import fixtures"
    /// button that feeds the committed fixture batch through
    /// `FixtureMediaProvider`s. Debug builds ONLY: a Release binary
    /// must have no reachable seeding path or KDF-downgrade seam
    /// (wave-001 claude-code #7) — the flag is compile-time false
    /// there.
    static var isUITestMode: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("-mobileseal-uitest")
        #else
            return false
        #endif
    }

    /// Present → the app container roots in a caller-named directory
    /// under the real Application Support (so a UI test can start
    /// from a clean vault, and relaunches within one test share
    /// state).
    static var containerOverride: String? {
        UserDefaults.standard.string(forKey: "mobileseal-uitest-container")
    }

    /// Present → the override container is deleted before use (each
    /// e2e test starts from a clean vault).
    static var wantsReset: Bool {
        UserDefaults.standard.bool(forKey: "mobileseal-uitest-reset")
    }

    /// Present → the committed PRE-MIGRATION fixture vault
    /// (`Fixtures/v0-vault/gallery`, format v0) is copied into the
    /// container before startup, so the scripted e2e exercises the
    /// transparent v0→v1 migration at unlock (CED-13 gate 2).
    static var wantsV0VaultSeed: Bool {
        UserDefaults.standard.bool(forKey: "mobileseal-uitest-seed-v0")
    }

    /// Copies the bundled v0 fixture gallery into the container
    /// (UI-test mode only; no-op when a gallery already exists, so
    /// relaunches keep the migrated state).
    static func seedV0VaultIfRequested(into container: AppContainer) {
        guard isUITestMode, wantsV0VaultSeed,
            container.existingGalleryDirectory() == nil,
            let bundled = Bundle.main.resourceURL?
                .appendingPathComponent("Fixtures/v0-vault/gallery", isDirectory: true),
            FileManager.default.fileExists(atPath: bundled.path)
        else { return }
        try? FileManager.default.copyItem(
            at: bundled, to: container.newGalleryDirectory())
    }

    /// The committed fixture batch (bundled under Fixtures/): sorted
    /// by name for deterministic ordering — mixed JPEG/HEIC, then the
    /// video matrix (fast-start MP4, tail-moov MOV, unsupported-codec
    /// MP4 — CED-12 gate 2), with the deliberately corrupt member
    /// LAST so the forced per-item failure lands after every
    /// successful import (a failure stops the batch). The first
    /// healthy image carries the paired MOV as a Live Photo pair.
    static func fixtureBatchProviders() -> [any MediaProvider] {
        guard
            let fixturesURL = Bundle.main.resourceURL?.appendingPathComponent(
                "Fixtures", isDirectory: true),
            let files = try? FileManager.default.contentsOfDirectory(
                at: fixturesURL, includingPropertiesForKeys: nil)
        else { return [] }
        let images = files.filter { ["jpg", "jpeg", "heic"].contains($0.pathExtension.lowercased()) }
        let (corrupt, healthy) = images.reduce(into: ([URL](), [URL]())) { acc, url in
            if url.lastPathComponent.hasPrefix("corrupt") {
                acc.0.append(url)
            } else {
                acc.1.append(url)
            }
        }
        let pairedVideoURL = fixturesURL.appendingPathComponent("video-paired.mov")
        let videos = files.filter {
            ["mp4", "mov"].contains($0.pathExtension.lowercased())
                && $0.lastPathComponent != pairedVideoURL.lastPathComponent
        }
        var providers: [any MediaProvider] = []
        for (i, url) in healthy.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .enumerated()
        {
            var provider = FixtureMediaProvider(fixtureURL: url)
            if i == 0, FileManager.default.fileExists(atPath: pairedVideoURL.path) {
                provider.pairedVideoURL = pairedVideoURL
            }
            providers.append(provider)
        }
        providers += videos.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { FixtureMediaProvider(fixtureURL: $0) }
        providers += corrupt.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { FixtureMediaProvider(fixtureURL: $0) }
        return providers
    }
}

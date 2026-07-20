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

    /// The committed fixture batch (bundled under Fixtures/): sorted
    /// by name for deterministic ordering — mixed JPEG/HEIC, with the
    /// deliberately corrupt member LAST so the forced per-item
    /// failure lands after ≥100 successful imports (gate 2).
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
        let ordered =
            healthy.sorted { $0.lastPathComponent < $1.lastPathComponent }
            + corrupt.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ordered.map { FixtureMediaProvider(fixtureURL: $0) }
    }
}

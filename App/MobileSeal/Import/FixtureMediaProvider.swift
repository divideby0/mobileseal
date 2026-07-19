import Foundation

/// Fixture-backed `MediaProvider` (Codex A6): the deterministic side
/// of the import seam. Behaviors cover the matrix the goal names —
/// success, cancellation, provider error, iCloud-download delay — and
/// staging cleanup falls out of the engine's normal lifecycle.
struct FixtureMediaProvider: MediaProvider {
    enum Behavior: Sendable {
        case success
        /// Simulates the user cancelling the provider load.
        case cancel
        /// Simulates a provider failure (unreadable asset).
        case error(String)
        /// Simulates an iCloud-download delay before success.
        case delay(TimeInterval)
    }

    let fixtureURL: URL
    var pairedVideoURL: URL?
    var behavior: Behavior = .success
    var uti: String?

    var suggestedName: String? { fixtureURL.lastPathComponent }

    func stageParts(into stagingDir: URL) async throws -> [StagedPart] {
        switch behavior {
        case .success:
            break
        case .cancel:
            throw MediaProviderError.cancelled
        case .error(let reason):
            throw MediaProviderError.loadFailed(reason)
        case .delay(let seconds):
            try await Task.sleep(for: .seconds(seconds))
        }
        var parts: [StagedPart] = []
        let stillDest = stagingDir.appendingPathComponent(fixtureURL.lastPathComponent)
        try FileManager.default.copyItem(at: fixtureURL, to: stillDest)
        parts.append(
            StagedPart(url: stillDest, role: .still, uti: uti ?? Self.utiFor(fixtureURL)))
        if let pairedVideoURL {
            let videoDest = stagingDir.appendingPathComponent(pairedVideoURL.lastPathComponent)
            try FileManager.default.copyItem(at: pairedVideoURL, to: videoDest)
            parts.append(
                StagedPart(
                    url: videoDest, role: .pairedVideo, uti: Self.utiFor(pairedVideoURL)))
        }
        return parts
    }

    static func utiFor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "heic": return "public.heic"
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "mov": return "com.apple.quicktime-movie"
        case "dng": return "com.adobe.raw-image"
        default: return "public.data"
        }
    }
}

import Foundation

/// The deterministic import seam (Codex A6): everything between "the
/// user picked things" and "plaintext parts sit in the staging dir"
/// hides behind this protocol, so success, cancellation, provider
/// error, iCloud-download delay, and cleanup are all simulator-testable
/// with fixture-backed fakes. The real PHPicker adapter
/// (`PickerMediaProvider`) is one implementation and gets a single
/// manual smoke test on device.
protocol MediaProvider: Sendable {
    /// Provider-suggested filename, when known.
    var suggestedName: String? { get }
    /// Copies the item's media parts into `stagingDir` and returns
    /// them. A Live Photo yields two parts (still + paired video —
    /// grill Q4: BOTH parts import). Throws `MediaProviderError` (or
    /// `CancellationError`). The returned URLs must live inside
    /// `stagingDir` — the custody audit walks that boundary.
    func stageParts(into stagingDir: URL) async throws -> [StagedPart]
}

/// One plaintext file staged for import.
struct StagedPart: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        /// The original media bytes (photo, or Live Photo still).
        case still
        /// The paired Live Photo video (imported as a linked entry).
        case pairedVideo
        /// An ordinary video as the item's PRIMARY media (CED-12 WS
        /// B.3) — imported byte-exact with a poster-frame thumbnail.
        case video
    }

    let url: URL
    let role: Role
    /// Uniform type identifier of the part's bytes, when known.
    let uti: String?
}

enum MediaProviderError: Error, Equatable {
    /// The provider could not produce a file representation.
    case loadFailed(String)
    /// The user cancelled the provider's load (distinct from batch
    /// cancellation, which arrives as `CancellationError`).
    case cancelled
    /// Staged bytes contradict their manifest (CED-15 WS B.2): the
    /// inbox item is corrupt — rejected before import, and the store
    /// DISCARDS it rather than releasing it to re-fail forever.
    case integrityMismatch(String)
}

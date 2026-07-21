import Foundation
import VaultCore

/// Adapts one committed (and claimed) inbox item to the import seam
/// (CED-15 WS B.2): the whole existing pipeline — staging discipline,
/// dedup, thumbnails, per-item commits — is reused unchanged. Manifest
/// integrity (byte length + BLAKE2b-256) is validated HERE, before any
/// bytes reach the vault: a truncated or substituted payload fails
/// typed (`integrityMismatch`) and never imports (Codex B9).
struct InboxMediaProvider: MediaProvider {
    let item: InboxStore.Item
    let store: InboxStore

    var suggestedName: String? {
        item.manifest.parts.first?.originalFilename
    }

    func stageParts(into stagingDir: URL) async throws -> [StagedPart] {
        var parts: [StagedPart] = []
        for part in item.manifest.parts {
            try Task.checkCancellation()
            let source = store.payloadURL(for: part)
            let length = try Self.length(of: source, part: part)
            guard length == part.byteLength else {
                throw MediaProviderError.integrityMismatch(
                    "\(part.file): length \(length) ≠ manifest \(part.byteLength)")
            }
            let hash = try MediaHashing.blake2b256Hex(of: source)
            guard hash == part.blake2b256 else {
                throw MediaProviderError.integrityMismatch(
                    "\(part.file): payload hash does not match manifest")
            }
            let name = part.originalFilename ?? part.file
            let dest = stagingDir.appendingPathComponent(
                "\(UUID().uuidString)-\((name as NSString).lastPathComponent)")
            do {
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                throw MediaProviderError.loadFailed(String(describing: error))
            }
            // Re-verify the COPY, not just the source (wave-001
            // coderabbit #1): a substitution between the source check
            // and the copy must not stage unverified bytes.
            let stagedLength = try Self.length(of: dest, part: part)
            guard stagedLength == part.byteLength else {
                throw MediaProviderError.integrityMismatch(
                    "\(part.file): staged length \(stagedLength) ≠ manifest \(part.byteLength)")
            }
            let stagedHash = try MediaHashing.blake2b256Hex(of: dest)
            guard stagedHash == part.blake2b256 else {
                throw MediaProviderError.integrityMismatch(
                    "\(part.file): staged payload hash does not match manifest")
            }
            parts.append(StagedPart(url: dest, role: Self.role(of: part.role), uti: part.uti))
        }
        return parts
    }

    private static func length(of url: URL, part: InboxManifest.Part) throws -> UInt64 {
        do {
            return try InboxWriter.fileLength(of: url)
        } catch {
            throw MediaProviderError.integrityMismatch("\(part.file): payload missing")
        }
    }

    private static func role(of role: InboxManifest.PartRole) -> StagedPart.Role {
        switch role {
        case .still: return .still
        case .pairedVideo: return .pairedVideo
        case .video: return .video
        }
    }
}

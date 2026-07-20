import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The real import seam (grill Q1): PHPicker copy-in ONLY — the picker
/// runs out of process, the app holds zero photo-library entitlement,
/// and no purpose string exists in the Info.plist. Full-library access
/// and the delete-originals "move" flow are deferred to the sync
/// milestone.
///
/// `NSItemProvider.loadFileRepresentation` writes a plaintext temp
/// file the system deletes when the completion handler returns — so
/// the file is copied into OUR protected staging dir inside the
/// handler (Codex B1), giving `Gallery.importFile` its seekable,
/// twice-readable source.
struct PickerMediaProvider: MediaProvider, @unchecked Sendable {
    // NSItemProvider is documented thread-safe but not marked
    // Sendable; the @unchecked conformance carries that contract.
    let itemProvider: NSItemProvider

    var suggestedName: String? { itemProvider.suggestedName }

    func stageParts(into stagingDir: URL) async throws -> [StagedPart] {
        // Live Photos (grill Q4): BOTH parts import. The picker's
        // provider serves a live-photo bundle; its contents are the
        // byte-exact still + paired video.
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier),
            let parts = try? await stageLivePhotoBundle(into: stagingDir),
            !parts.isEmpty
        {
            return parts
        }
        // Ordinary video (CED-12 WS B.3): the item's primary media is
        // audiovisual — byte-exact copy-in, same as stills.
        if let movieType = itemProvider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .movie) == true
        }) {
            let url = try await loadFileCopy(
                typeIdentifier: movieType, into: stagingDir,
                preferredName: itemProvider.suggestedName)
            return [StagedPart(url: url, role: .video, uti: movieType)]
        }
        // Plain still: prefer the item's registered image type so HEIC
        // stays HEIC and ProRAW stays ProRAW (byte-exact originals).
        let imageType =
            itemProvider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier
        let url = try await loadFileCopy(
            typeIdentifier: imageType, into: stagingDir,
            preferredName: itemProvider.suggestedName)
        return [StagedPart(url: url, role: .still, uti: imageType)]
    }

    /// Loads the live-photo bundle representation and copies the still
    /// + video out of it.
    private func stageLivePhotoBundle(into stagingDir: URL) async throws -> [StagedPart] {
        let bundleURL = try await loadFileCopy(
            typeIdentifier: UTType.livePhoto.identifier, into: stagingDir,
            preferredName: nil)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let contents = try FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: nil)
        var parts: [StagedPart] = []
        for file in contents {
            let type = UTType(filenameExtension: file.pathExtension)
            let dest = stagingDir.appendingPathComponent(file.lastPathComponent)
            if type?.conforms(to: .image) == true {
                try FileManager.default.moveItem(at: file, to: dest)
                parts.append(StagedPart(url: dest, role: .still, uti: type?.identifier))
            } else if type?.conforms(to: .audiovisualContent) == true {
                try FileManager.default.moveItem(at: file, to: dest)
                parts.append(StagedPart(url: dest, role: .pairedVideo, uti: type?.identifier))
            }
        }
        // A bundle without a still is not a usable Live Photo import.
        guard parts.contains(where: { $0.role == .still }) else {
            throw MediaProviderError.loadFailed("live photo bundle had no still part")
        }
        return parts
    }

    /// Bridges `loadFileRepresentation` to async, copying into staging
    /// INSIDE the completion handler (the source is gone afterwards).
    private func loadFileCopy(
        typeIdentifier: String, into stagingDir: URL, preferredName: String?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(
                        throwing: MediaProviderError.loadFailed(
                            error.map(String.init(describing:)) ?? "no file representation"))
                    return
                }
                let name = preferredName.flatMap { $0.isEmpty ? nil : $0 }
                let dest = stagingDir.appendingPathComponent(
                    "\(UUID().uuidString)-\(name ?? url.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    continuation.resume(returning: dest)
                } catch {
                    continuation.resume(
                        throwing: MediaProviderError.loadFailed(String(describing: error)))
                }
            }
        }
    }
}

/// SwiftUI wrapper for `PHPickerViewController`.
struct PhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([any MediaProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        // Videos admitted since CED-12 (the playback leg); audio has
        // no picker path — video-only is the grill Q4 scope.
        config.filter = .any(of: [.images, .livePhotos, .videos])
        config.selectionLimit = 0  // unlimited; batch semantics own failure
        config.preferredAssetRepresentationMode = .current  // byte-exact
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([any MediaProvider]) -> Void
        init(onPicked: @escaping ([any MediaProvider]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onPicked(results.map { PickerMediaProvider(itemProvider: $0.itemProvider) })
        }
    }
}

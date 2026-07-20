import SwiftUI
import UIKit
import VaultCore

/// Bounded still viewer (GOAL WS C.3): full-res decode under
/// `StillDecoder`'s explicit ceiling, pinch zoom via UIScrollView.
/// Live Photos show the still until the Playback leg; integrity
/// failures explain themselves per GOAL WS D.5.
struct DetailView: View {
    let item: MediaItem
    let store: VaultStore

    @State private var image: UIImage?
    @State private var failure: String?
    @State private var loadTask: Task<Result<UIImage?, VaultError>, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea()
                } else if let failure {
                    ContentUnavailableView(
                        "Can't show this photo",
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(item.filename ?? "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if item.isLivePhotoStill {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label("Live Photo (still only this release)", systemImage: "livephoto")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .task { await load() }
            .onDisappear {
                // The decode Task is cancellable and dies with the
                // view — a lock tears the view down, cancelling any
                // in-flight decode (wave-001 codex #3).
                loadTask?.cancel()
                image = nil
            }
        }
    }

    /// Total-operation memory ceiling (wave-001 codex #4): the whole-
    /// file read materializes ~2× the source bytes plus the decoded
    /// bitmap; sources above this bound are refused with an honest
    /// message. A chunked/streaming decode seam belongs to the
    /// Playback leg (GOAL WS B.1 defers streaming sources).
    static let maxSourceBytes: UInt64 = 256 << 20

    private func load() async {
        guard item.byteLength <= Self.maxSourceBytes else {
            failure =
                "This original is larger than the viewer's memory budget for this release (\(ByteCountFormatter.string(fromByteCount: Int64(Self.maxSourceBytes), countStyle: .file))). The stored bytes are intact."
            return
        }
        guard let reader = await store.thumbnails.currentReader() else {
            failure = "The vault is locked."
            return
        }
        let fileID = item.id
        let length = item.byteLength
        let task = Task<Result<UIImage?, VaultError>, Never>(priority: .userInitiated) {
            do {
                let data = try VaultCoordinator.decryptWhole(
                    fileID: fileID, length: length, reader: reader)
                if Task.isCancelled { return .success(nil) }
                return .success(StillDecoder.decode(data: data))
            } catch let error as VaultError {
                return .failure(error)
            } catch {
                return .failure(.ioFailure(operation: "read", path: ""))
            }
        }
        loadTask = task
        let result = await task.value
        guard !Task.isCancelled else { return }

        switch result {
        case .success(let decoded?):
            image = decoded
        case .success(nil):
            if failure == nil, !Task.isCancelled {
                failure = "The original could not be decoded. The stored bytes are intact."
            }
        case .failure(let error):
            switch error {
            case .missingChunk:
                // Only genuine integrity failures mark the item
                // damaged (wave-001 coderabbit #1): a transient
                // vaultLocked is not damage.
                store.markDamaged(item.id)
                failure =
                    "Part of this photo's encrypted data is missing from the vault. The rest of your library is unaffected."
            case .authenticationFailed:
                store.markDamaged(item.id)
                failure =
                    "This photo's encrypted data failed its integrity check — it may have been corrupted or tampered with. The rest of your library is unaffected."
            case .vaultLocked:
                failure = "The vault locked while loading."
            default:
                failure = "Reading failed: \(String(describing: error))"
            }
        }
    }
}

/// Minimal pinch-zoom host: UIScrollView with a centered UIImageView.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

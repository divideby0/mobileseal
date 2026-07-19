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
        }
    }

    private func load() async {
        guard let reader = await store.thumbnails.currentReader() else {
            failure = "The vault is locked."
            return
        }
        let fileID = item.id
        let length = item.byteLength
        let result: Result<UIImage?, VaultError> = await Task.detached(priority: .userInitiated) {
            do {
                let data = try VaultCoordinator.decryptWhole(
                    fileID: fileID, length: length, reader: reader)
                return .success(StillDecoder.decode(data: data))
            } catch let error as VaultError {
                return .failure(error)
            } catch {
                return .failure(.ioFailure(operation: "read", path: ""))
            }
        }.value

        switch result {
        case .success(let decoded?):
            image = decoded
        case .success(nil):
            failure = "The original could not be decoded. The stored bytes are intact."
        case .failure(let error):
            store.markDamaged(item.id)
            switch error {
            case .missingChunk:
                failure =
                    "Part of this photo's encrypted data is missing from the vault. The rest of your library is unaffected."
            case .authenticationFailed:
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

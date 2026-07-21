import UIKit
import UniformTypeIdentifiers

/// One staged file as the share sheet consumes it (CED-15 WS A.1,
/// Codex B1): a FILE-URL item via `UIActivityItemSource` — never an
/// in-memory data item — with the preserved original filename as the
/// subject and the stored UTI as the item's declared type. The
/// `itemForActivityType` method IS the consumption seam gate 2 drives
/// directly (simulating Photos/Files/AirDrop asking for the item).
final class ExportActivityItem: NSObject, UIActivityItemSource {
    let file: ExportFileItem

    init(file: ExportFileItem) {
        self.file = file
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        file.url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        file.url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        file.uti ?? UTType.data.identifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        file.filename
    }
}

/// The export share flow (CED-15 WS A.1): generic pre-share custody
/// warning → stage to StagingExport/ → UIActivityViewController with
/// file-URL items → sweep at completion/cancellation. The warning is
/// generic by design — the share sheet cannot reveal the chosen
/// destination — and says plainly that delivered bytes are beyond
/// recall (Codex B4/A5).
@MainActor
enum ExportShareFlow {
    /// The presented sheet, torn down without animation when the vault
    /// leaves the unlocked phase (mirrors MediaPagerPresenter).
    private(set) static weak var activeSheet: UIActivityViewController?

    static func warningTitle(count: Int) -> String {
        count == 1 ? "Share this item?" : "Share \(count) items?"
    }

    static let warningMessage = """
        Sharing decrypts exact copies and hands them to the app or \
        destination you choose next — MobileSeal cannot see which, and \
        some destinations sync through iCloud. Once delivered, those \
        copies are outside the vault and cannot be recalled. Leaving \
        the app cancels a share in progress. Live Photos share as two \
        files (photo + video).
        """

    /// Stages `items` and presents the share sheet from the topmost
    /// controller over `anchor`. Call AFTER the warning was confirmed.
    static func stageAndPresent(
        store: VaultStore, items: [MediaItem], anchor: UIView?
    ) {
        Task {
            guard let batch = await store.beginExport(items) else { return }
            presentSheet(store: store, batch: batch, anchor: anchor, retriesLeft: 8)
        }
    }

    private static func presentSheet(
        store: VaultStore, batch: ExportBatch, anchor: UIView?, retriesLeft: Int
    ) {
        // The vault may have locked between staging and presentation
        // (the participant already swept the batch) — never present
        // a sheet over dead files.
        guard store.phase.isUnlocked else {
            store.finishExport(batch.id)
            return
        }
        let presenter = anchor?.topmostViewController ?? Self.keyWindowTopmost()
        let midTransition =
            presenter == nil
            || presenter?.isBeingDismissed == true
            || presenter?.isBeingPresented == true
        if midTransition {
            guard retriesLeft > 0 else {
                store.finishExport(batch.id)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                presentSheet(
                    store: store, batch: batch, anchor: anchor,
                    retriesLeft: retriesLeft - 1)
            }
            return
        }
        let sheet = UIActivityViewController(
            activityItems: batch.files.map { ExportActivityItem(file: $0) },
            applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            // Completion AND cancellation both sweep (gate 2); bytes an
            // activity copied before this are past the custody
            // boundary (Codex A5).
            Task { @MainActor in store.finishExport(batch.id) }
        }
        if let popover = sheet.popoverPresentationController, let anchor {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        activeSheet = sheet
        presenter?.present(sheet, animated: true)
    }

    /// Lock path companion (mid-share lock, gate 2): the sheet must
    /// not outlive the unlocked phase — its items are already swept.
    static func dismissActive() {
        guard let sheet = activeSheet else { return }
        activeSheet = nil
        sheet.presentingViewController?.dismiss(animated: false)
    }

    private static func keyWindowTopmost() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let window = scenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

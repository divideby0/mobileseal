import UIKit
import UniformTypeIdentifiers

/// The share-extension entry point (CED-15 WS B.1): stages incoming
/// media into the protected app-group inbox and NOTHING else — no
/// unlock, no KDF (the 120 MB extension memory limit is why the
/// extension never touches Argon2id), no Keychain. The main app
/// discovers committed items and prompts on its next
/// activation/unlock/switch.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var stagingTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        stagingTask = Task { await stage() }
    }

    private func buildUI() {
        statusLabel.text = "Staging for MobileSeal…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "share-status"

        spinner.startAnimating()

        doneButton.setTitle("Done", for: .normal)
        doneButton.isEnabled = false
        doneButton.addAction(
            UIAction { [weak self] _ in
                self?.extensionContext?.completeRequest(returningItems: [])
            }, for: .touchUpInside)
        doneButton.accessibilityIdentifier = "share-done"

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addAction(
            UIAction { [weak self] _ in self?.cancel() }, for: .touchUpInside)
        cancelButton.accessibilityIdentifier = "share-cancel"

        let stack = UIStackView(arrangedSubviews: [
            statusLabel, spinner, doneButton, cancelButton,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func stage() async {
        guard let store = InboxStore.appGroup() else {
            finishStaging(message: "MobileSeal's shared inbox is unavailable.")
            return
        }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
            .map { ProviderInboxAttachment(itemProvider: $0) }
        guard !attachments.isEmpty else {
            finishStaging(message: "Nothing to stage.")
            return
        }
        let writer = InboxWriter(store: store)
        let outcomes = await writer.stage(attachments: attachments)

        var staged = 0
        var skipped = 0
        var failed = 0
        var firstFailure: InboxError?
        for outcome in outcomes {
            switch outcome.status {
            case .staged: staged += 1
            case .skippedNotMedia: skipped += 1
            case .failed(let error):
                failed += 1
                if firstFailure == nil { firstFailure = error }
            }
        }
        var lines: [String] = []
        if staged > 0 {
            lines.append(
                "Staged \(staged) \(staged == 1 ? "item" : "items") for MobileSeal — open the app to import."
            )
        }
        if skipped > 0 {
            lines.append("\(skipped) skipped (only photos and videos can be staged).")
        }
        if failed > 0 {
            lines.append("\(failed) failed: \(Self.describe(firstFailure))")
        }
        if lines.isEmpty { lines = ["Nothing was staged."] }
        finishStaging(message: lines.joined(separator: "\n"))
    }

    private func finishStaging(message: String) {
        statusLabel.text = message
        spinner.stopAnimating()
        spinner.isHidden = true
        doneButton.isEnabled = true
        cancelButton.isHidden = true
    }

    private func cancel() {
        stagingTask?.cancel()
        // The writer removes the in-flight item's partial files on
        // cancellation (typed cleanup); anything already committed
        // stays committed — cancel means "stop", not "unshare".
        extensionContext?.cancelRequest(
            withError: CocoaError(.userCancelled))
    }

    private static func describe(_ error: InboxError?) -> String {
        switch error {
        case .diskFull:
            return "not enough free space."
        case .quotaExceeded:
            return "the staging inbox is full — import or discard staged items in MobileSeal."
        case .cancelled:
            return "cancelled."
        case .loadFailed, .copyFailed, .malformedManifest, .containerUnavailable, .none:
            return "the item could not be read."
        }
    }
}

import AVFoundation
import UIKit
import VaultCore

/// Photos-lite pager (CED-12 WS C.1, grill Q1): hard-snap paging via
/// UIPageViewController, tile↔detail zoom morph on open/close, and an
/// interactive swipe-down dismiss. Zoom-carryover and pinch-to-grid
/// stay deferred (map fog).
///
/// Playback policy (WS C.2, grill Q3): landing on a video autoplays
/// MUTED and looping; tap toggles sound; Live Photos auto-play motion
/// once. One-active-player rule: only the LANDED page ever creates a
/// player item (through `PlaybackController`); neighbors get poster +
/// leading-range warming, invalidated by the controller's generation
/// token on fast swipes.
@MainActor
final class MediaPagerViewController: UIPageViewController {
    let store: VaultStore
    private(set) var items: [MediaItem]
    private(set) var currentIndex: Int
    /// Frame provider for the zoom morph: the grid supplies the
    /// CURRENT item's cell frame in window coordinates (nil when
    /// scrolled away — the morph falls back to a fade).
    let sourceFrame: (FileID) -> CGRect?

    private let dimmingView = UIView()
    private var interactiveDismissActive = false

    init(
        store: VaultStore, items: [MediaItem], startIndex: Int,
        sourceFrame: @escaping (FileID) -> CGRect?
    ) {
        self.store = store
        self.items = items
        self.currentIndex = startIndex
        self.sourceFrame = sourceFrame
        super.init(
            transitionStyle: .scroll, navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12])
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    var currentItem: MediaItem { items[currentIndex] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "media-pager"
        dataSource = self
        delegate = self
        setViewControllers(
            [makePage(at: currentIndex)], direction: .forward, animated: false)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let close = UIButton(type: .close)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(
            UIAction { [weak self] _ in self?.animateDismiss() }, for: .touchUpInside)
        close.accessibilityIdentifier = "pager-close"
        view.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
        ])

        // Single delete (CED-13 WS C.2): confirmation → soft delete
        // into Recently Deleted; the pager advances like Photos.
        var trashConfig = UIButton.Configuration.plain()
        trashConfig.image = UIImage(systemName: "trash")
        trashConfig.baseForegroundColor = .white
        let trash = UIButton(configuration: trashConfig)
        trash.translatesAutoresizingMaskIntoConstraints = false
        trash.addAction(
            UIAction { [weak self] _ in self?.confirmDeleteCurrent() }, for: .touchUpInside)
        trash.accessibilityIdentifier = "pager-delete"
        view.addSubview(trash)
        NSLayoutConstraint.activate([
            trash.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            trash.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])

        if UITestSupport.isUITestMode {
            installPlaybackDebugOverlay()
        }
    }

    // MARK: - UI-test instrumentation (gate 4: prefetch discipline)

    private let debugLabel = UILabel()
    private var debugTask: Task<Void, Never>?

    /// Machine-readable playback counters for the fast-swipe gate:
    /// `players=<n> requests=<n> cacheBytes=<n> budget=<n>`. Debug
    /// UI-test mode only — Release has no reachable path here.
    private func installPlaybackDebugOverlay() {
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        debugLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        debugLabel.textColor = .secondaryLabel
        debugLabel.accessibilityIdentifier = "playback-debug"
        view.addSubview(debugLabel)
        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            debugLabel.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        debugTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let playback = self.store.playback
                let players = playback.player == nil ? 0 : 1
                let requests = playback.debugActiveRequestCount
                let stats = await playback.debugCacheStats()
                // activations/warms make the gate NON-tautological:
                // player-item creations and warm-task cancellations
                // can actually exceed their bounds when the
                // one-active-player or token discipline breaks
                // (wave-001 claude-code #5).
                let line =
                    "players=\(players) requests=\(requests) "
                    + "cacheBytes=\(stats.residentBytes) budget=\(stats.budgetBytes) "
                    + "activations=\(playback.debugPlayerActivations) "
                    + "warms=\(playback.debugWarmsStarted) "
                    + "warmsCancelled=\(playback.debugWarmsCancelled) "
                    + "warmsInFlight=\(playback.debugInFlightWarmCount)"
                self.debugLabel.text = line
                self.debugLabel.accessibilityValue = line
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    deinit {
        debugTask?.cancel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        landed(on: currentIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        store.playback.releasePlayer()
    }

    // MARK: - pages

    private func makePage(at index: Int) -> MediaPageViewController {
        let page = MediaPageViewController(item: items[index], store: store)
        page.pageIndex = index
        return page
    }

    /// The one-active-player transition: release the old player,
    /// activate the landed page, warm neighbors through the provider.
    private func landed(on index: Int) {
        currentIndex = index
        store.noteInteraction()
        guard let page = viewControllers?.first as? MediaPageViewController else { return }
        store.playback.releasePlayer()
        page.didLand()
        // Neighbor warming (Codex A3): poster + leading ranges only —
        // never a player item; stale tokens die on the next landing.
        for neighbor in [index - 1, index + 1] where items.indices.contains(neighbor) {
            let item = items[neighbor]
            Task { await store.thumbnails.prefetch([item]) }
            if item.isVideo {
                store.playback.warmNeighbor(fileID: item.id, byteLength: item.byteLength)
            }
        }
    }

    // MARK: - delete (CED-13 WS C.2)

    /// Photos-parity single delete: confirmation sheet → soft delete
    /// (Recently Deleted) → advance to the next item, or dismiss when
    /// the pager empties.
    private func confirmDeleteCurrent() {
        let item = currentItem
        let alert = UIAlertController(
            title: "Remove this item?",
            message:
                "It moves to Recently Deleted for \(RecentlyDeletedStore.retentionDays) days, then is removed from the vault.",
            preferredStyle: .actionSheet)
        let remove = UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            self?.deleteItem(item)
        }
        remove.accessibilityLabel = "confirm-pager-remove"
        alert.addAction(remove)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        present(alert, animated: true)
    }

    private func deleteItem(_ item: MediaItem) {
        store.softDelete([item.id])
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: index)
        guard !items.isEmpty else {
            animateDismiss()
            return
        }
        let nextIndex = min(index, items.count - 1)
        currentIndex = nextIndex
        store.playback.releasePlayer()
        setViewControllers(
            [makePage(at: nextIndex)], direction: .forward, animated: true
        ) { [weak self] _ in
            self?.landed(on: nextIndex)
        }
    }

    // MARK: - dismissal

    func animateDismiss() {
        store.playback.releasePlayer()
        dismiss(animated: true)
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let progress = max(0, translation.y / view.bounds.height)
        guard let content = viewControllers?.first?.view else { return }
        switch pan.state {
        case .began:
            interactiveDismissActive = true
        case .changed:
            guard interactiveDismissActive else { return }
            let scale = max(0.6, 1 - progress * 0.4)
            content.transform = CGAffineTransform(
                translationX: translation.x, y: max(0, translation.y)
            ).scaledBy(x: scale, y: scale)
            view.backgroundColor = .black.withAlphaComponent(1 - progress)
        case .ended, .cancelled:
            guard interactiveDismissActive else { return }
            interactiveDismissActive = false
            let velocity = pan.velocity(in: view).y
            if progress > 0.3 || velocity > 900 {
                animateDismiss()
            } else {
                UIView.animate(withDuration: 0.25) {
                    content.transform = .identity
                    self.view.backgroundColor = .black
                }
            }
        default:
            break
        }
    }
}

extension MediaPagerViewController: UIPageViewControllerDataSource,
    UIPageViewControllerDelegate, UIGestureRecognizerDelegate
{
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? MediaPageViewController,
            page.pageIndex > 0
        else { return nil }
        return makePage(at: page.pageIndex - 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? MediaPageViewController,
            page.pageIndex < items.count - 1
        else { return nil }
        return makePage(at: page.pageIndex + 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed,
            let page = viewControllers?.first as? MediaPageViewController
        else { return }
        landed(on: page.pageIndex)
    }

    /// The dismiss pan only begins on a clearly-vertical drag, so it
    /// never fights the pager's horizontal scroll or the scrubber.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        return v.y > abs(v.x) * 1.5
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

// MARK: - presenter + zoom morph

/// Presents the pager full-screen with the tile↔detail zoom morph,
/// and owns the "lock dismisses the pager" rule: `dismissActive()`
/// tears the presentation down without animation when the vault
/// leaves the unlocked phase.
@MainActor
enum MediaPagerPresenter {
    private(set) static weak var active: MediaPagerViewController?

    static func present(
        store: VaultStore, items: [MediaItem], startIndex: Int,
        anchor: UIView,
        sourceFrame: @escaping (FileID) -> CGRect?
    ) {
        let pager = MediaPagerViewController(
            store: store, items: items, startIndex: startIndex, sourceFrame: sourceFrame)
        pager.modalPresentationStyle = .fullScreen
        pager.transitioningDelegate = ZoomMorphTransition.shared
        active = pager
        attemptPresent(pager, anchor: anchor, retriesLeft: 8)
    }

    /// Presenting while another modal (the import-summary sheet) is
    /// still dismissing silently fails in UIKit — re-derive the
    /// topmost controller and retry briefly instead of dropping the
    /// tap.
    private static func attemptPresent(
        _ pager: MediaPagerViewController, anchor: UIView, retriesLeft: Int
    ) {
        let presenter = anchor.topmostViewController
        let midTransition =
            presenter == nil
            || presenter?.isBeingDismissed == true
            || presenter?.isBeingPresented == true
        if midTransition {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                attemptPresent(pager, anchor: anchor, retriesLeft: retriesLeft - 1)
            }
            return
        }
        presenter?.present(pager, animated: true)
    }

    /// Lock path: the presented pager must not outlive the unlocked
    /// phase (its pages hold decoded plaintext imagery).
    static func dismissActive() {
        guard let pager = active else { return }
        active = nil
        pager.presentingViewController?.dismiss(animated: false)
    }
}

/// Zoom morph (grill Q1): the poster/thumbnail image flies from the
/// grid tile to the detail frame on present, and back to the CURRENT
/// item's tile on dismiss (hard-snap pagers may dismiss from a
/// different item than they opened on). Falls back to a fade when the
/// tile is off-screen.
final class ZoomMorphTransition: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = ZoomMorphTransition()

    func animationController(
        forPresented presented: UIViewController, presenting: UIViewController,
        source: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        (presented as? MediaPagerViewController).map { ZoomMorphAnimator(pager: $0, presenting: true) }
    }

    func animationController(forDismissed dismissed: UIViewController)
        -> (any UIViewControllerAnimatedTransitioning)?
    {
        (dismissed as? MediaPagerViewController).map { ZoomMorphAnimator(pager: $0, presenting: false) }
    }
}

@MainActor
final class ZoomMorphAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let pager: MediaPagerViewController
    let presenting: Bool

    init(pager: MediaPagerViewController, presenting: Bool) {
        self.pager = pager
        self.presenting = presenting
    }

    nonisolated func transitionDuration(
        using context: (any UIViewControllerContextTransitioning)?
    ) -> TimeInterval { 0.32 }

    nonisolated func animateTransition(using context: any UIViewControllerContextTransitioning) {
        MainActor.assumeIsolated {
            animateOnMain(using: context)
        }
    }

    private func animateOnMain(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        let item = pager.currentItem
        let tileFrame = pager.sourceFrame(item.id)

        if presenting {
            guard let toView = context.view(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            toView.frame = container.bounds
            container.addSubview(toView)
            guard let tileFrame else {
                toView.alpha = 0
                UIView.animate(
                    withDuration: transitionDuration(using: context),
                    animations: { toView.alpha = 1 },
                    completion: { _ in context.completeTransition(true) })
                return
            }
            // Morph: scale the whole pager out of the tile.
            let target = container.bounds
            let scaleX = tileFrame.width / target.width
            let scaleY = tileFrame.height / target.height
            let scale = max(scaleX, scaleY)
            toView.transform = CGAffineTransform(scaleX: scale, y: scale)
            toView.center = CGPoint(x: tileFrame.midX, y: tileFrame.midY)
            toView.alpha = 0.4
            UIView.animate(
                withDuration: transitionDuration(using: context), delay: 0,
                usingSpringWithDamping: 0.9, initialSpringVelocity: 0.4,
                animations: {
                    toView.transform = .identity
                    toView.center = CGPoint(x: target.midX, y: target.midY)
                    toView.alpha = 1
                },
                completion: { _ in context.completeTransition(true) })
        } else {
            guard let fromView = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            // A .fullScreen presentation REMOVED the presenter's view;
            // a custom dismissal animator must reinstall it or the
            // window is left empty after the transition.
            if let toView = context.view(forKey: .to) {
                toView.frame = container.bounds
                container.insertSubview(toView, belowSubview: fromView)
            }
            let duration = transitionDuration(using: context)
            UIView.animate(
                withDuration: duration,
                animations: {
                    if let tileFrame {
                        let scale = max(
                            tileFrame.width / fromView.bounds.width,
                            tileFrame.height / fromView.bounds.height)
                        fromView.transform = fromView.transform.concatenating(
                            CGAffineTransform(scaleX: scale, y: scale))
                        fromView.center = CGPoint(x: tileFrame.midX, y: tileFrame.midY)
                    }
                    fromView.alpha = 0
                },
                completion: { _ in context.completeTransition(true) })
        }
    }
}

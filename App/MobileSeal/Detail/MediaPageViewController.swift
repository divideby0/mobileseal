import AVFoundation
import UIKit
import VaultCore

/// One pager page (CED-12 WS C): a zoomable still, or a streamed
/// video with muted autoplay + tap-for-sound + plain scrubber. Player
/// items exist ONLY while this page is the landed page (`didLand` /
/// pager teardown via `PlaybackController.releasePlayer`).
///
/// External-playback truth table (grill Q2 + Codex B7):
///   external playback ACTIVE            → local layer may blank
///                                         (video plays on the TV);
///                                         capture shield EXEMPT.
///   scene capture ACTIVE, no external   → local player BLANKED
///   (recording/mirroring)                 behind an explanatory
///                                         cover.
///   neither                             → normal local playback.
/// Detection uses the current scene-capture trait
/// (`UITraitCollection.sceneCaptureState`), never the deprecated
/// `UIScreen.isCaptured`.
@MainActor
final class MediaPageViewController: UIViewController {
    let item: MediaItem
    let store: VaultStore
    var pageIndex = 0

    // Still presentation.
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var decodeTask: Task<Void, Never>?

    // Video presentation.
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var statusObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    private var muteButton = UIButton(configuration: .filled())
    private let scrubber = UISlider()
    private var timeObserver: Any?
    private var loopObserver: NSObjectProtocol?
    private let captureCover = UIView()
    private let stateLabel = UILabel()

    // Live Photo motion-once.
    private var motionPlayed = false

    init(item: MediaItem, store: VaultStore) {
        self.item = item
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        decodeTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "media-page-\(item.id.description)"

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.maximumZoomScale = item.isVideo ? 1 : 4
        scrollView.minimumZoomScale = 1
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textColor = .white
        stateLabel.font = .preferredFont(forTextStyle: .callout)
        stateLabel.numberOfLines = 0
        stateLabel.textAlignment = .center
        stateLabel.isHidden = true
        view.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        // Poster first (from the encrypted thumbnail cache), so every
        // page has content the instant it scrolls in.
        let target = item
        decodeTask = Task { [weak self] in
            if let poster = await self?.store.thumbnails.image(for: target) {
                if Task.isCancelled { return }
                self?.imageView.image = poster
            }
            guard let self, !target.isVideo else { return }
            await self.decodeFullStill()
        }

        if item.isVideo {
            installVideoChrome()
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
        captureCover.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        decodeTask?.cancel()
        detachPlayer()
    }

    // MARK: - landing (the one-active-player entry point)

    /// The pager landed on this page: start whatever playback the
    /// item calls for (grill Q3).
    func didLand() {
        if item.isVideo {
            startVideoPlayback()
        } else if item.livePhotoVideoID != nil, !motionPlayed {
            playLivePhotoMotionOnce()
        }
    }

    // MARK: - stills

    private func decodeFullStill() async {
        guard item.byteLength > 0, item.byteLength <= 256 << 20,
            let reader = await store.thumbnails.currentReader()
        else { return }
        let fileID = item.id
        let length = item.byteLength
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard
                let data = try? VaultCoordinator.decryptWhole(
                    fileID: fileID, length: length, reader: reader)
            else { return nil }
            return StillDecoder.decode(data: data)
        }.value
        guard !Task.isCancelled, let decoded else { return }
        imageView.image = decoded
    }

    // MARK: - video

    private func installVideoChrome() {
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.configuration?.image = UIImage(systemName: "speaker.slash.fill")
        muteButton.configuration?.baseBackgroundColor = .black.withAlphaComponent(0.5)
        muteButton.accessibilityIdentifier = "mute-toggle"
        muteButton.addAction(
            UIAction { [weak self] _ in self?.toggleMute() }, for: .touchUpInside)
        view.addSubview(muteButton)

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.accessibilityIdentifier = "video-scrubber"
        scrubber.addAction(
            UIAction { [weak self] _ in self?.scrubberMoved() }, for: .valueChanged)
        view.addSubview(scrubber)

        captureCover.backgroundColor = .black
        captureCover.isHidden = true
        captureCover.accessibilityIdentifier = "capture-cover"
        let coverLabel = UILabel()
        coverLabel.text = "Playback hidden while the screen is being recorded or mirrored"
        coverLabel.textColor = .secondaryLabel
        coverLabel.font = .preferredFont(forTextStyle: .footnote)
        coverLabel.numberOfLines = 0
        coverLabel.textAlignment = .center
        coverLabel.translatesAutoresizingMaskIntoConstraints = false
        captureCover.addSubview(coverLabel)
        view.addSubview(captureCover)

        NSLayoutConstraint.activate([
            muteButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            muteButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scrubber.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            scrubber.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            scrubber.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            coverLabel.centerXAnchor.constraint(equalTo: captureCover.centerXAnchor),
            coverLabel.centerYAnchor.constraint(equalTo: captureCover.centerYAnchor),
            coverLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: captureCover.leadingAnchor, constant: 24),
            coverLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: captureCover.trailingAnchor, constant: -24),
        ])

        // Scene-capture state is a trait (iOS 17+): re-evaluate the
        // truth table whenever recording/mirroring starts or stops.
        registerForTraitChanges([UITraitSceneCaptureState.self]) {
            (self: Self, _: UITraitCollection) in
            self.applyCaptureTruthTable()
        }
    }

    private func startVideoPlayback() {
        guard player == nil else {
            player?.play()
            return
        }
        guard
            let player = store.playback.activatePlayer(
                fileID: item.id, uti: item.uti, byteLength: item.byteLength)
        else {
            showState("The vault is locked.")
            return
        }
        attach(player: player, muted: true, looping: true)
        player.play()
    }

    /// Live Photo motion (grill Q3): the paired video plays ONCE,
    /// muted, over the still — through the same streaming path (no
    /// plaintext file ever exists for it) — then the still returns.
    private func playLivePhotoMotionOnce() {
        guard let videoID = item.livePhotoVideoID, item.livePhotoVideoByteLength > 0,
            let player = store.playback.activatePlayer(
                fileID: videoID, uti: item.livePhotoVideoUTI ?? "com.apple.quicktime-movie",
                byteLength: item.livePhotoVideoByteLength)
        else { return }
        motionPlayed = true
        attach(player: player, muted: true, looping: false)
        player.play()
    }

    private func attach(player: AVPlayer, muted: Bool, looping: Bool) {
        self.player = player
        player.isMuted = muted
        // External playback ALLOWED (grill Q2: "it's my TV").
        player.allowsExternalPlayback = true

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, above: scrollView.layer)
        playerLayer = layer
        view.bringSubviewToFront(captureCover)
        view.bringSubviewToFront(muteButton)
        view.bringSubviewToFront(scrubber)

        if let item = player.currentItem {
            statusObservation = item.observe(\.status) { [weak self] observed, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if observed.status == .failed {
                        self.showPlaybackFailure()
                    }
                }
            }
            // An unsupported codec never fails the item's status — it
            // just reports unplayable (Codex A6): probe explicitly so
            // "can't play this format" actually shows.
            let asset = item.asset
            Task { [weak self] in
                let playable = (try? await asset.load(.isPlayable)) ?? true
                if !playable {
                    self?.showPlaybackFailure()
                }
            }
        }
        externalObservation = player.observe(\.isExternalPlaybackActive) {
            [weak self] _, _ in
            Task { @MainActor in self?.applyCaptureTruthTable() }
        }
        if looping {
            loopObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: player.currentItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.player else { return }
                    player.seek(to: .zero)
                    player.play()
                }
            }
        } else {
            loopObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: player.currentItem, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.endLivePhotoMotion() }
            }
        }
        if item.isVideo {
            installTimeObserver(player)
        }
        applyCaptureTruthTable()
    }

    private func endLivePhotoMotion() {
        detachPlayer()
        store.playback.releasePlayer()
    }

    private func detachPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation = nil
        externalObservation = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
        loopObserver = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
    }

    private func installTimeObserver(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, let duration = self.player?.currentItem?.duration.seconds,
                    duration.isFinite, duration > 0, !self.scrubber.isTracking
                else { return }
                self.scrubber.value = Float(time.seconds / duration)
            }
        }
    }

    private func scrubberMoved() {
        guard let player, let duration = player.currentItem?.duration.seconds,
            duration.isFinite, duration > 0
        else { return }
        let target = CMTime(
            seconds: Double(scrubber.value) * duration,
            preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        store.noteInteraction()
    }

    private func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        muteButton.configuration?.image = UIImage(
            systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        store.noteInteraction()
    }

    @objc private func handleTap() {
        if item.isVideo {
            // Tap toggles sound (grill Q3) — the whole surface, not
            // just the button.
            toggleMute()
        }
    }

    // MARK: - failure states (Codex A6)

    private func showPlaybackFailure() {
        if store.playback.activeItemSawIntegrityFailure {
            store.markDamaged(item.id)
            showState(
                "Part of this video's encrypted data is damaged or missing. "
                    + "The rest of your library is unaffected.")
            view.accessibilityValue = "damaged"
        } else {
            showState("Can't play this video's format on this device.")
            view.accessibilityValue = "unsupported-format"
        }
        playerLayer?.removeFromSuperlayer()
        scrubber.isHidden = true
        muteButton.isHidden = true
    }

    private func showState(_ message: String) {
        stateLabel.text = message
        stateLabel.isHidden = false
        stateLabel.accessibilityIdentifier = "playback-state"
    }

    // MARK: - capture truth table (WS C.4)

    private func applyCaptureTruthTable() {
        guard item.isVideo || item.livePhotoVideoID != nil else { return }
        let captured = traitCollection.sceneCaptureState == .active
        let external = player?.isExternalPlaybackActive ?? false
        // Blank the LOCAL player only when captured and NOT routing
        // externally: AirPlay external playback is exempt (grill Q2);
        // recording/mirroring without external playback blanks.
        captureCover.isHidden = !(captured && !external)
    }
}

extension MediaPageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        item.isVideo ? nil : imageView
    }
}

import OSLog
import SwiftUI
import UIKit
import VaultCore

/// Photos-style grid (GOAL WS C.1): `UICollectionView` + compositional
/// layout wrapped for SwiftUI; diffable data source keyed by `FileID`;
/// cancelable prefetch/decrypt through `ThumbnailPipeline`, with
/// cell-reuse cancellation. Fed exclusively from the store's items
/// (which flow from `Gallery.snapshotStream()` — never the
/// unlock-frozen session snapshot).
struct PhotoGridView: UIViewRepresentable {
    var items: [MediaItem]
    let pipeline: ThumbnailPipeline
    var onSelect: (MediaItem) -> Void
    var onScroll: () -> Void

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = .systemBackground
        collectionView.accessibilityIdentifier = "photo-grid"
        context.coordinator.install(in: collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(items)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// 3-across adaptive square cells, tight gutters — the Photos look.
    static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let columns = max(3, Int(environment.container.effectiveContentSize.width / 130))
            let spacing: CGFloat = 2
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                heightDimension: .fractionalHeight(1.0))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalWidth(1.0 / CGFloat(columns)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize, repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            return section
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching, UIScrollViewDelegate
    {
        var parent: PhotoGridView
        private var dataSource: UICollectionViewDiffableDataSource<Int, FileID>?
        private var itemsByID: [FileID: MediaItem] = [:]

        init(parent: PhotoGridView) {
            self.parent = parent
        }

        func install(in collectionView: UICollectionView) {
            let registration = UICollectionView.CellRegistration<PhotoCell, FileID> {
                [weak self] cell, _, fileID in
                guard let self, let item = self.itemsByID[fileID] else { return }
                cell.configure(with: item, pipeline: self.parent.pipeline)
            }
            dataSource = UICollectionViewDiffableDataSource<Int, FileID>(
                collectionView: collectionView
            ) { collectionView, indexPath, fileID in
                collectionView.dequeueConfiguredReusableCell(
                    using: registration, for: indexPath, item: fileID)
            }
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
        }

        func apply(_ items: [MediaItem]) {
            itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var snapshot = NSDiffableDataSourceSnapshot<Int, FileID>()
            snapshot.appendSections([0])
            snapshot.appendItems(items.map(\.id))
            // Reconfigure so damage badges / thumbnail arrivals update
            // in place.
            snapshot.reconfigureItems(items.map(\.id))
            dataSource?.apply(snapshot, animatingDifferences: false)
        }

        func collectionView(
            _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
        ) {
            collectionView.deselectItem(at: indexPath, animated: false)
            guard let id = dataSource?.itemIdentifier(for: indexPath),
                let item = itemsByID[id]
            else { return }
            parent.onSelect(item)
        }

        // MARK: prefetch (Codex A3)

        func collectionView(
            _ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]
        ) {
            let items = indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }
                .compactMap { itemsByID[$0] }
            let pipeline = parent.pipeline
            Task { await pipeline.prefetch(items) }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cancelPrefetchingForItemsAt indexPaths: [IndexPath]
        ) {
            let ids = indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) }
            let pipeline = parent.pipeline
            Task { await pipeline.cancel(ids) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.onScroll()
        }

        // MARK: scroll-perf instrumentation (gate 3)

        // CADisplayLink frame-gap tracking while scrolling, active in
        // UI-test mode only; results surface through the collection
        // view's accessibilityValue for the perf test to read, and an
        // os_signpost interval brackets each scroll for Instruments.
        private var displayLink: CADisplayLink?
        /// The previous callback's `targetTimestamp` — the moment the
        /// NEXT frame was promised. Comparing the next callback's
        /// actual timestamp against it measures LATENESS in a way
        /// that tracks ProMotion's adaptive refresh rate; a naive
        /// interval-vs-last-interval heuristic misreads every
        /// legitimate cadence drop (120→80→40 Hz during
        /// deceleration) as a hitch — the device spot-check reported
        /// a 45% "hitch ratio" that way.
        private var lastTargetTimestamp: CFTimeInterval = 0
        private var frameCount = 0
        private var hitchCount = 0
        private var maxGapMs = 0.0
        private weak var instrumentedScrollView: UIScrollView?
        private var signpostState: OSSignpostIntervalState?
        private static let signposter = OSSignposter(
            subsystem: "com.gmail.cedric.hurst.mobileseal", category: "grid-scroll")

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard UITestSupport.isUITestMode, displayLink == nil else { return }
            instrumentedScrollView = scrollView
            // Per-scroll counters: each published report describes
            // exactly one scroll interval — the perf test sums them
            // (wave-001 claude-code #3: cumulative counters inflated
            // the recorded numbers).
            lastTargetTimestamp = 0
            frameCount = 0
            hitchCount = 0
            maxGapMs = 0
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            signpostState = Self.signposter.beginInterval("scroll")
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishInstrumenting(scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
            // A drag released without velocity never decelerates — tear
            // down here or the link runs forever (wave-001 cc #12).
            if !willDecelerate { finishInstrumenting(scrollView) }
        }

        private func finishInstrumenting(_ scrollView: UIScrollView) {
            guard let link = displayLink else { return }
            link.invalidate()
            displayLink = nil
            if let state = signpostState {
                Self.signposter.endInterval("scroll", state)
                signpostState = nil
            }
            scrollView.accessibilityValue = String(
                format: "frames=%d hitches=%d maxGapMs=%.1f",
                frameCount, hitchCount, maxGapMs)
        }

        @objc private func frame(_ link: CADisplayLink) {
            if lastTargetTimestamp > 0 {
                // Lateness past the promised presentation time.
                // On-time frames land at ≈0 regardless of the
                // display's current adaptive rate; a hitch is a frame
                // arriving more than one 120 Hz interval late.
                let latenessMs = (link.timestamp - lastTargetTimestamp) * 1000
                frameCount += 1
                maxGapMs = max(maxGapMs, max(0, latenessMs))
                if latenessMs > 8.4 { hitchCount += 1 }
            }
            lastTargetTimestamp = link.targetTimestamp
        }
    }
}

/// One grid cell: async thumbnail via the pipeline, cancelled on
/// reuse; damage and no-preview badges per GOAL WS D.5.
final class PhotoCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let badge = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var loadedID: FileID?
    private var pipeline: ThumbnailPipeline?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.tintColor = .systemYellow
        badge.isHidden = true
        contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        // Cancellation must reach the underlying decrypt/decode, not
        // just the waiting UI task (wave-001 codex #6).
        if let id = loadedID, let pipeline {
            Task { await pipeline.cancel([id]) }
        }
        loadedID = nil
        imageView.image = nil
        badge.isHidden = true
    }

    func configure(with item: MediaItem, pipeline: ThumbnailPipeline) {
        loadedID = item.id
        self.pipeline = pipeline
        accessibilityIdentifier = "photo-cell-\(item.id.description)"
        if item.damaged {
            badge.image = UIImage(systemName: "exclamationmark.triangle.fill")
            badge.isHidden = false
            accessibilityValue = "damaged"
        } else if item.thumbnailID == nil {
            badge.image = UIImage(systemName: "eye.slash.fill")
            badge.isHidden = false
            accessibilityValue = "no preview"
        } else {
            badge.isHidden = true
            accessibilityValue = nil
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await pipeline.image(for: item)
            guard !Task.isCancelled else { return }
            self?.imageView.image = image
        }
    }

}

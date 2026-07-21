import Foundation
import VaultCore

/// One soft-deleted media AGGREGATE (CED-13 WS C.2, reviews B13/Q6):
/// delete targets the logical media item — the original plus its
/// linked thumbnail / Live-Photo entries — never a bare entry.
struct SoftDeletedAggregate: Codable, Equatable, Sendable {
    /// The top-level (grid-visible) entry.
    let originalID: String
    /// EVERY entry in the aggregate, original included — exactly the
    /// set purge tombstones.
    let memberIDs: [String]
    let deletedAt: Date

    var originalFileID: FileID? {
        UUID(uuidString: originalID).map(FileID.init(uuid:))
    }

    var memberFileIDs: [FileID] {
        memberIDs.compactMap { UUID(uuidString: $0).map(FileID.init(uuid:)) }
    }

    func expiresAt(retention: TimeInterval) -> Date {
        deletedAt.addingTimeInterval(retention)
    }
}

/// The device-local soft-delete ledger — "delete for myself" (CED-13
/// WS C.2). DEVICE-LOCAL this leg by scope decision (review B6/Q3:
/// the per-user merge algebra is designed at the sync leg); it lives
/// in the container's DeviceLocal directory, outside the vault,
/// excluded from backup. Records file IDs and dates only — no
/// plaintext, no keys; the entries themselves stay (encrypted) in the
/// manifest until purge/expiry emits hard tombstones.
final class RecentlyDeletedStore: @unchecked Sendable {
    /// iPhone-parity retention: 30 days, then hard-tombstoned.
    static let retentionDays = 30
    static let retention: TimeInterval = TimeInterval(retentionDays) * 24 * 60 * 60

    private let url: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.url = fileURL
    }

    private func load() -> [SoftDeletedAggregate] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SoftDeletedAggregate].self, from: data)) ?? []
    }

    private func save(_ aggregates: [SoftDeletedAggregate]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(aggregates) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    var all: [SoftDeletedAggregate] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func softDelete(originalID: FileID, memberIDs: [FileID], at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var aggregates = load()
        guard !aggregates.contains(where: { $0.originalID == originalID.description }) else {
            return
        }
        aggregates.append(
            SoftDeletedAggregate(
                originalID: originalID.description,
                memberIDs: memberIDs.map(\.description),
                deletedAt: date))
        save(aggregates)
    }

    /// Restore clears the soft state — the entries were never touched.
    /// Returns the removed aggregate (nil when unknown).
    @discardableResult
    func remove(originalID: FileID) -> SoftDeletedAggregate? {
        lock.lock()
        defer { lock.unlock() }
        var aggregates = load()
        guard let index = aggregates.firstIndex(where: {
            $0.originalID == originalID.description
        }) else { return nil }
        let removed = aggregates.remove(at: index)
        save(aggregates)
        return removed
    }

    /// Aggregates past the retention window as of `now`.
    func expired(asOf now: Date = Date()) -> [SoftDeletedAggregate] {
        all.filter { $0.expiresAt(retention: Self.retention) <= now }
    }

    /// Drops ledger rows whose entries no longer exist in the manifest
    /// (e.g. purged by another flow) so the ledger cannot grow stale.
    func compact(keepingKnown known: Set<FileID>) {
        lock.lock()
        defer { lock.unlock() }
        let aggregates = load()
        let live = aggregates.filter { agg in
            agg.originalFileID.map { known.contains($0) } ?? false
        }
        if live.count != aggregates.count { save(live) }
    }
}

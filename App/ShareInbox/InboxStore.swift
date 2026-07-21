import Foundation

/// The app-group inbox (CED-15 WS B): a protected staging area OUTSIDE
/// the app sandbox that the share extension writes and the main app
/// drains. App-group containers inherit neither Data Protection nor
/// backup exclusion (Codex B7), so BOTH are applied per file here.
///
/// Item states (Codex B6), derived from what exists on disk:
///   incomplete — payload file(s) present, no manifest (a copy in
///                flight, or a crash's leavings; stale ones sweep)
///   committed  — manifest present and valid (the atomic commit point)
///   claimed    — committed + a main-app claim marker (an import owns
///                it; released back to committed if the import dies)
///   imported / discarded — files removed (terminal)
///
/// The main-app launch sweep removes ONLY stale incompletes and
/// malformed manifests, and releases orphaned claims — the app's
/// wipe-all staging behavior explicitly does NOT apply here.
struct InboxStore: Sendable {
    /// Quota defaults (Codex A3): 2 GiB or 50 items, whichever trips
    /// first. Instance-tunable for tests only — production always
    /// runs the defaults.
    static let defaultMaxTotalBytes: Int64 = 2 << 30
    static let defaultMaxItemCount = 50
    /// An incomplete item older than this is stale (its writer is
    /// dead — extension copies are seconds, not minutes).
    static let defaultStaleAfter: TimeInterval = 900
    /// Disk-space safety factor for incoming copies (mirrors
    /// ImportEngine.lowDiskFactor).
    static let lowDiskFactor: Int64 = 2

    var maxTotalBytes: Int64 = InboxStore.defaultMaxTotalBytes
    var maxItemCount: Int = InboxStore.defaultMaxItemCount
    var staleAfter: TimeInterval = InboxStore.defaultStaleAfter

    let inboxDir: URL
    /// Injectable free-space probe (tests force the disk-full path).
    var availableCapacity: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    init(inboxDir: URL) throws {
        self.inboxDir = inboxDir
        try FileManager.default.createDirectory(
            at: inboxDir, withIntermediateDirectories: true)
        Self.applyCustody(to: inboxDir)
    }

    /// The production inbox in the shared app-group container; nil
    /// when the container is unavailable (missing entitlement).
    static func appGroup() -> InboxStore? {
        guard
            let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: InboxStore.appGroupIdentifier)
        else { return nil }
        return try? InboxStore(
            inboxDir: root.appendingPathComponent("Inbox", isDirectory: true))
    }

    static let appGroupIdentifier = "group.com.gmail.cedric.hurst.mobileseal"

    // MARK: - custody (Codex B7)

    /// Per-file Data Protection + backup exclusion, applied EXPLICITLY
    /// to everything the inbox writes: the app-group container is
    /// outside the app sandbox and inherits neither. Best-effort on
    /// simulator; device enforcement is the stated residual.
    static func applyCustody(to url: URL) {
        #if os(iOS)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path)
        #endif
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    // MARK: - discovery

    struct Item: Sendable, Equatable, Identifiable {
        let manifest: InboxManifest
        let claim: InboxClaim?
        var id: UUID { manifest.itemID }
        var isClaimed: Bool { claim != nil }
        var totalBytes: Int64 {
            manifest.parts.reduce(0) { $0 + Int64($1.byteLength) }
        }
    }

    struct Scan: Sendable, Equatable {
        var committed: [Item] = []
        var claimed: [Item] = []
        /// Payload/temp files with no manifest, by item stem.
        var incomplete: [URL] = []
        /// Manifest files that failed decode/validation.
        var malformed: [URL] = []
    }

    /// Classifies everything currently in the inbox. Committed items
    /// sort oldest-first (the quota expiry order).
    func scan() -> Scan {
        var result = Scan()
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: inboxDir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return result }

        var manifests: [UUID: InboxManifest] = [:]
        var claims: [UUID: InboxClaim] = [:]
        var payloads: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            if name == Self.noticesName { continue }
            if name.hasSuffix(".manifest.json") {
                do {
                    let manifest = try InboxManifest.decode(try Data(contentsOf: url))
                    guard name == InboxManifest.manifestName(itemID: manifest.itemID) else {
                        throw InboxError.malformedManifest("manifest name mismatch")
                    }
                    manifests[manifest.itemID] = manifest
                } catch {
                    result.malformed.append(url)
                }
            } else if name.hasSuffix(".claim.json") {
                if let claim = try? InboxJSON.decoder().decode(
                    InboxClaim.self, from: Data(contentsOf: url)),
                    let itemID = UUID(uuidString: String(name.dropLast(".claim.json".count)))
                {
                    claims[itemID] = claim
                } else {
                    result.malformed.append(url)
                }
            } else if name == Self.promptedName {
                continue
            } else {
                payloads.append(url)
            }
        }

        var referenced: Set<String> = []
        for (itemID, manifest) in manifests {
            // A manifest whose payloads vanished is as malformed as a
            // truncated one — it can never import.
            let complete = manifest.parts.allSatisfy {
                fm.fileExists(atPath: inboxDir.appendingPathComponent($0.file).path)
            }
            guard complete else {
                result.malformed.append(
                    inboxDir.appendingPathComponent(InboxManifest.manifestName(itemID: itemID)))
                continue
            }
            for part in manifest.parts { referenced.insert(part.file) }
            let item = Item(manifest: manifest, claim: claims[itemID])
            if item.isClaimed {
                result.claimed.append(item)
            } else {
                result.committed.append(item)
            }
        }
        result.incomplete = payloads.filter { !referenced.contains($0.lastPathComponent) }
        // Deterministic oldest-first (wave-001 codex #5): fractional
        // committedAt, itemID as the total-order tie-breaker.
        result.committed.sort {
            ($0.manifest.committedAt, $0.id.uuidString)
                < ($1.manifest.committedAt, $1.id.uuidString)
        }
        result.claimed.sort {
            ($0.manifest.committedAt, $0.id.uuidString)
                < ($1.manifest.committedAt, $1.id.uuidString)
        }
        return result
    }

    // MARK: - launch sweep (Codex B6)

    struct SweepReport: Sendable, Equatable {
        var staleIncompleteRemoved = 0
        var malformedRemoved = 0
        var claimsReleased = 0
    }

    /// Main-app launch recovery: stale incompletes and malformed
    /// manifests (with their payloads) are removed; ALL claims release
    /// back to committed — no import survives the app process, so an
    /// existing claim marker is always an orphan at launch. Committed
    /// items are NEVER touched here.
    @discardableResult
    func sweepAtLaunch(now: Date = Date()) -> SweepReport {
        var report = SweepReport()
        let fm = FileManager.default
        let scanned = scan()
        for url in scanned.incomplete {
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > staleAfter {
                try? fm.removeItem(at: url)
                report.staleIncompleteRemoved += 1
            }
        }
        for url in scanned.malformed {
            // A malformed manifest's referenced payloads (if any
            // decodably exist) become unreferenced incompletes and
            // sweep on a later launch; the manifest itself goes now.
            try? fm.removeItem(at: url)
            report.malformedRemoved += 1
        }
        for item in scanned.claimed {
            releaseClaim(itemID: item.id)
            report.claimsReleased += 1
        }
        return report
    }

    // MARK: - claims (CED-15 WS B.2)

    /// All-or-nothing across the batch (wave-001 codex #4): a failed
    /// marker write rolls back every marker already written, so a
    /// recoverable I/O error never leaves half the batch claimed and
    /// invisible for the rest of the session.
    func claim(itemIDs: [UUID], galleryID: UUID, now: Date = Date()) throws {
        let claim = InboxClaim(galleryID: galleryID, claimedAt: now)
        let data = try InboxJSON.encoder().encode(claim)
        var written: [URL] = []
        do {
            for itemID in itemIDs {
                let url = inboxDir.appendingPathComponent(
                    InboxManifest.claimName(itemID: itemID))
                try data.write(to: url, options: [.atomic])
                written.append(url)
                Self.applyCustody(to: url)
            }
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    func releaseClaim(itemID: UUID) {
        try? FileManager.default.removeItem(
            at: inboxDir.appendingPathComponent(InboxManifest.claimName(itemID: itemID)))
    }

    /// Terminal removal — imported or user-discarded: payloads,
    /// manifest, claim marker.
    func remove(itemID: UUID) {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: inboxDir, includingPropertiesForKeys: nil)
        else { return }
        let prefix = itemID.uuidString.lowercased()
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - quota (Codex A3)

    struct QuotaPlan: Sendable, Equatable {
        struct Victim: Sendable, Equatable {
            let item: Item
            let reason: InboxExpiryNotice.Reason
        }

        /// Oldest-first committed victims that must expire for the
        /// incoming item to fit.
        var victims: [Victim] = []
    }

    /// Computes the expiry plan for an incoming item WITHOUT deleting
    /// anything (wave-001 codex #2: victims are evicted only after
    /// the incoming manifest durably commits, via
    /// `executeQuotaPlan`). Oldest committed UNCLAIMED items are the
    /// victims; claimed items never expire — an import owns them.
    /// Throws `.quotaExceeded` when the incoming item alone cannot
    /// fit even after evicting everything evictable.
    func planQuota(incomingBytes: Int64, incomingItems: Int = 1) throws -> QuotaPlan {
        guard incomingBytes <= maxTotalBytes, incomingItems <= maxItemCount else {
            throw InboxError.quotaExceeded
        }
        var plan = QuotaPlan()
        var scanned = scan()
        var totalBytes =
            scanned.committed.reduce(0) { $0 + $1.totalBytes }
            + scanned.claimed.reduce(0) { $0 + $1.totalBytes }
        var totalItems = scanned.committed.count + scanned.claimed.count
        while totalBytes + incomingBytes > maxTotalBytes
            || totalItems + incomingItems > maxItemCount
        {
            guard !scanned.committed.isEmpty else { throw InboxError.quotaExceeded }
            let oldest = scanned.committed.removeFirst()
            let reason: InboxExpiryNotice.Reason =
                totalBytes + incomingBytes > maxTotalBytes ? .quotaBytes : .quotaCount
            plan.victims.append(QuotaPlan.Victim(item: oldest, reason: reason))
            totalBytes -= oldest.totalBytes
            totalItems -= 1
        }
        return plan
    }

    /// Executes a quota plan AFTER the incoming commit: victims are
    /// removed with notices. A victim CLAIMED since the plan was
    /// computed is skipped (wave-001 claude-code #2 — narrows the
    /// cross-process claim/expiry TOCTOU; the quota is then
    /// transiently over and the next writer's plan trims further).
    /// Residual race (recorded, accepted this leg): with no
    /// interprocess lock, a claim landing between this existence
    /// check and the removal still loses its payloads — the import
    /// then fails typed (`integrityMismatch`, payload missing) and
    /// the item is discarded, which is the same terminal state quota
    /// expiry intended.
    func executeQuotaPlan(_ plan: QuotaPlan, now: Date = Date()) {
        guard !plan.victims.isEmpty else { return }
        var expired: [InboxExpiryNotice] = []
        let fm = FileManager.default
        for victim in plan.victims {
            let claimURL = inboxDir.appendingPathComponent(
                InboxManifest.claimName(itemID: victim.item.id))
            guard !fm.fileExists(atPath: claimURL.path) else { continue }
            remove(itemID: victim.item.id)
            expired.append(
                InboxExpiryNotice(
                    itemID: victim.item.id,
                    originalFilename: victim.item.manifest.parts.first?.originalFilename,
                    expiredAt: now, reason: victim.reason))
        }
        if !expired.isEmpty {
            appendNotices(expired)
        }
    }

    // MARK: - notices

    static let noticesName = "notices.json"

    private var noticesURL: URL { inboxDir.appendingPathComponent(Self.noticesName) }

    func appendNotices(_ notices: [InboxExpiryNotice]) {
        var all = readNotices()
        all.append(contentsOf: notices)
        if let data = try? InboxJSON.encoder().encode(all) {
            try? data.write(to: noticesURL, options: [.atomic])
            Self.applyCustody(to: noticesURL)
        }
    }

    func readNotices() -> [InboxExpiryNotice] {
        guard let data = try? Data(contentsOf: noticesURL) else { return [] }
        return (try? InboxJSON.decoder().decode([InboxExpiryNotice].self, from: data)) ?? []
    }

    /// Reads and clears pending notices (the prompt consumed them).
    func takeNotices() -> [InboxExpiryNotice] {
        let notices = readNotices()
        try? FileManager.default.removeItem(at: noticesURL)
        return notices
    }

    // MARK: - prompted ledger (wave-001 claude-code #3)

    /// The exactly-once-per-batch prompt guarantee survives relaunch:
    /// prompted (accepted OR declined) item IDs persist beside the
    /// items they describe, so a declined batch re-offers only
    /// alongside NEW arrivals — never merely because the app
    /// restarted. Pruned to live items on every write.
    static let promptedName = "prompted.json"

    private var promptedURL: URL { inboxDir.appendingPathComponent(Self.promptedName) }

    func readPromptedIDs() -> Set<UUID> {
        guard let data = try? Data(contentsOf: promptedURL) else { return [] }
        return (try? InboxJSON.decoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    func markPrompted(_ ids: [UUID]) {
        let scanned = scan()
        let live = Set(scanned.committed.map(\.id)).union(scanned.claimed.map(\.id))
        let merged = readPromptedIDs().intersection(live).union(ids)
        if let data = try? InboxJSON.encoder().encode(merged) {
            try? data.write(to: promptedURL, options: [.atomic])
            Self.applyCustody(to: promptedURL)
        }
    }

    // MARK: - payload access

    func payloadURL(for part: InboxManifest.Part) -> URL {
        inboxDir.appendingPathComponent(part.file)
    }
}

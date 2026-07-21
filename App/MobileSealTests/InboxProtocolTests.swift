import Foundation
import Testing
import UniformTypeIdentifiers
import VaultCore

@testable import MobileSeal

/// A deterministic `InboxAttachment` (the extension seam's fake half,
/// mirroring FixtureMediaProvider): serves file representations from
/// fixture copies, with failure/delay behaviors for the commit matrix.
struct FakeAttachment: InboxAttachment {
    enum Behavior: Sendable {
        case success
        case failLoad(String)
        case delay(TimeInterval)
    }

    var registeredTypeIdentifiers: [String]
    var suggestedName: String?
    /// UTI → source URL served for that representation. A directory
    /// URL models the live-photo bundle.
    var representations: [String: URL]
    var behavior: Behavior = .success

    func loadFileRepresentation(
        typeIdentifier: String, handler: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) {
        let representations = self.representations
        let behavior = self.behavior
        Task.detached {
            switch behavior {
            case .success:
                break
            case .failLoad(let reason):
                handler(nil, TestError(reason))
                return
            case .delay(let seconds):
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard let source = representations[typeIdentifier] else {
                handler(nil, TestError("no representation for \(typeIdentifier)"))
                return
            }
            // Mirror NSItemProvider: hand out a TEMP copy that dies
            // when the handler returns.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-attachment-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: source, to: tmp)
            } catch {
                handler(nil, error)
                return
            }
            handler(tmp, nil)
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

/// CED-15 gate 3 (protocol half): the inbox writer/store as a library
/// — atomic manifest-last commit, malformed/truncated rejection,
/// states + sweep rules, quota/expiry with notices, disk-full typed
/// refusal, live-photo preference order, concurrent-invocation naming,
/// and termination-mid-copy leaving only incomplete state.
@Suite struct InboxProtocolTests {

    private func makeInbox() throws -> InboxStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-tests-\(UUID().uuidString)/Inbox", isDirectory: true)
        return try InboxStore(inboxDir: dir)
    }

    private func destroy(_ store: InboxStore) {
        try? FileManager.default.removeItem(at: store.inboxDir.deletingLastPathComponent())
    }

    private func jpegAttachment(
        _ fixture: String = "fixture-0000.jpg", name: String? = nil
    ) throws -> FakeAttachment {
        let url = try TestSupport.fixtureURL(fixture)
        return FakeAttachment(
            registeredTypeIdentifiers: [UTType.jpeg.identifier],
            suggestedName: name ?? fixture,
            representations: [UTType.jpeg.identifier: url])
    }

    // MARK: - atomic commit (Codex B9)

    @Test func commitIsManifestLastAndValidated() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }
        let writer = InboxWriter(store: inbox)

        let outcomes = await writer.stage(attachments: [try jpegAttachment()])
        guard case .staged(let manifest) = outcomes[0].status else {
            Issue.record("expected staged, got \(outcomes[0].status)")
            return
        }
        #expect(manifest.schemaVersion == InboxManifest.currentSchemaVersion)
        #expect(manifest.pairing == .single)
        #expect(manifest.parts.count == 1)
        let part = manifest.parts[0]
        #expect(part.role == .still)
        #expect(part.uti == UTType.jpeg.identifier)
        #expect(part.originalFilename == "fixture-0000.jpg")

        // The payload's recorded hash + length match the actual bytes.
        let payload = inbox.payloadURL(for: part)
        let bytes = try Data(contentsOf: payload)
        #expect(UInt64(bytes.count) == part.byteLength)
        #expect(try MediaHashing.blake2b256Hex(of: bytes) == part.blake2b256)
        // …and equal the source fixture byte-for-byte.
        #expect(bytes == (try Data(contentsOf: TestSupport.fixtureURL("fixture-0000.jpg"))))

        let scan = inbox.scan()
        #expect(scan.committed.count == 1)
        #expect(scan.incomplete.isEmpty)
        #expect(scan.malformed.isEmpty)
    }

    /// Extension death mid-copy (gate 3): payloads without a manifest
    /// are exactly the incomplete state — never visible as committed,
    /// swept once stale.
    @Test func terminationMidCopyLeavesOnlyIncompleteThenSweeps() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }

        // "Died before the manifest write": a bare payload file.
        let itemID = UUID()
        let orphan = inbox.inboxDir.appendingPathComponent(
            InboxManifest.payloadName(itemID: itemID, index: 0))
        try Data("partial".utf8).write(to: orphan)

        var scan = inbox.scan()
        #expect(scan.committed.isEmpty)
        #expect(scan.incomplete.count == 1)

        // Fresh incompletes survive the sweep (a copy may be live)…
        var report = inbox.sweepAtLaunch()
        #expect(report.staleIncompleteRemoved == 0)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        // …stale ones go.
        report = inbox.sweepAtLaunch(now: Date().addingTimeInterval(InboxStore.defaultStaleAfter + 60))
        #expect(report.staleIncompleteRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        scan = inbox.scan()
        #expect(scan.incomplete.isEmpty)
    }

    @Test func malformedAndForeignManifestsRejectedAndSwept() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }

        // Garbage JSON.
        let garbage = inbox.inboxDir.appendingPathComponent(
            InboxManifest.manifestName(itemID: UUID()))
        try Data("not json".utf8).write(to: garbage)
        // Structurally valid JSON whose parts point at a FOREIGN file.
        let foreignID = UUID()
        let foreign = InboxManifest(
            schemaVersion: 1, itemID: foreignID, pairing: .single,
            committedAt: Date(), sourceApp: nil,
            parts: [
                InboxManifest.Part(
                    role: .still, file: "../../escape.jpg", originalFilename: nil,
                    uti: "public.jpeg", byteLength: 1,
                    blake2b256: String(repeating: "a", count: 64))
            ])
        try foreign.encoded().write(
            to: inbox.inboxDir.appendingPathComponent(
                InboxManifest.manifestName(itemID: foreignID)))
        // A manifest whose payload vanished (truncated commit).
        let truncatedID = UUID()
        let truncated = InboxManifest(
            schemaVersion: 1, itemID: truncatedID, pairing: .single,
            committedAt: Date(), sourceApp: nil,
            parts: [
                InboxManifest.Part(
                    role: .still,
                    file: InboxManifest.payloadName(itemID: truncatedID, index: 0),
                    originalFilename: nil, uti: "public.jpeg", byteLength: 10,
                    blake2b256: String(repeating: "b", count: 64))
            ])
        try truncated.encoded().write(
            to: inbox.inboxDir.appendingPathComponent(
                InboxManifest.manifestName(itemID: truncatedID)))

        let scan = inbox.scan()
        #expect(scan.committed.isEmpty)
        #expect(scan.malformed.count == 3)

        let report = inbox.sweepAtLaunch()
        #expect(report.malformedRemoved == 3)
        #expect(inbox.scan().malformed.isEmpty)
    }

    @Test func unsupportedSchemaVersionRejects() throws {
        let id = UUID()
        let future = """
            {"schemaVersion":9,"itemID":"\(id.uuidString)","pairing":"single",
            "committedAt":"2026-07-21T00:00:00Z","parts":[]}
            """
        #expect(throws: InboxError.self) {
            _ = try InboxManifest.decode(Data(future.utf8))
        }
    }

    // MARK: - states + claims

    @Test func claimsReleaseAtLaunchAndOnRelease() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }
        let writer = InboxWriter(store: inbox)
        _ = await writer.stage(attachments: [try jpegAttachment()])
        let item = try #require(inbox.scan().committed.first)

        try inbox.claim(itemIDs: [item.id], galleryID: UUID())
        var scan = inbox.scan()
        #expect(scan.committed.isEmpty)
        #expect(scan.claimed.count == 1)

        // Launch sweep: no import survives the previous process — the
        // orphan claim releases, the committed item PERSISTS (the
        // wipe-all staging rule explicitly does not apply).
        let report = inbox.sweepAtLaunch()
        #expect(report.claimsReleased == 1)
        scan = inbox.scan()
        #expect(scan.committed.count == 1)
        #expect(scan.claimed.isEmpty)
    }

    // MARK: - quota + expiry (Codex A3)

    @Test func itemCountQuotaExpiresOldestWithNotice() async throws {
        var inbox = try makeInbox()
        inbox.maxItemCount = 2
        defer { destroy(inbox) }
        let writer = InboxWriter(store: inbox)

        _ = await writer.stage(attachments: [try jpegAttachment(name: "oldest.jpg")])
        try await Task.sleep(for: .milliseconds(1100))  // ISO8601 second granularity
        _ = await writer.stage(attachments: [try jpegAttachment(name: "middle.jpg")])
        try await Task.sleep(for: .milliseconds(1100))
        _ = await writer.stage(attachments: [try jpegAttachment(name: "newest.jpg")])

        let scan = inbox.scan()
        #expect(scan.committed.count == 2)
        let names = scan.committed.compactMap { $0.manifest.parts.first?.originalFilename }
        #expect(names == ["middle.jpg", "newest.jpg"])

        let notices = inbox.takeNotices()
        #expect(notices.count == 1)
        #expect(notices.first?.originalFilename == "oldest.jpg")
        #expect(notices.first?.reason == .quotaCount)
        // takeNotices consumed them.
        #expect(inbox.readNotices().isEmpty)
    }

    @Test func byteQuotaExpiresOldestAndSingleOversizeRefusesTyped() async throws {
        var inbox = try makeInbox()
        inbox.maxTotalBytes = 20_000  // fixtures are ~9 KB
        defer { destroy(inbox) }
        let writer = InboxWriter(store: inbox)

        _ = await writer.stage(attachments: [try jpegAttachment(name: "first.jpg")])
        try await Task.sleep(for: .milliseconds(1100))
        _ = await writer.stage(attachments: [try jpegAttachment("fixture-0002.jpg", name: "second.jpg")])
        try await Task.sleep(for: .milliseconds(1100))
        // Third pushes total past 20 KB → oldest expires.
        _ = await writer.stage(attachments: [try jpegAttachment("fixture-0004.jpg", name: "third.jpg")])
        let scan = inbox.scan()
        let names = scan.committed.compactMap { $0.manifest.parts.first?.originalFilename }
        #expect(!names.contains("first.jpg"))
        #expect(inbox.takeNotices().contains { $0.reason == .quotaBytes })

        // A single item that can NEVER fit refuses typed, staging
        // nothing and expiring nothing.
        var tiny = inbox
        tiny.maxTotalBytes = 100
        let before = tiny.scan().committed.count
        let outcomes = await InboxWriter(store: tiny).stage(
            attachments: [try jpegAttachment(name: "oversize.jpg")])
        guard case .failed(.quotaExceeded) = outcomes[0].status else {
            Issue.record("expected quotaExceeded, got \(outcomes[0].status)")
            return
        }
        #expect(tiny.scan().committed.count == before)
        #expect(tiny.scan().incomplete.isEmpty, "a refused item must not strand payloads")
    }

    // MARK: - disk-full (Codex B8)

    @Test func lowDiskRefusesTypedWithNoPartials() async throws {
        var inbox = try makeInbox()
        defer { destroy(inbox) }
        inbox.availableCapacity = { _ in 1_000 }  // fixtures need ~18 KB at 2×
        let writer = InboxWriter(store: inbox)

        let outcomes = await writer.stage(attachments: [try jpegAttachment()])
        guard case .failed(.diskFull(let required, let available)) = outcomes[0].status else {
            Issue.record("expected diskFull, got \(outcomes[0].status)")
            return
        }
        #expect(available == 1_000)
        #expect(required > available)
        let scan = inbox.scan()
        #expect(scan.committed.isEmpty)
        #expect(scan.incomplete.isEmpty, "a refused copy must not strand payloads")
    }

    // MARK: - live-photo preference order (Codex B10)

    @Test func livePhotoBundlePreferredOverSplitRepresentations() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }

        // Build a live-photo "bundle": a directory holding still+video.
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.copyItem(
            at: try TestSupport.fixtureURL("fixture-0002.jpg"),
            to: bundle.appendingPathComponent("IMG_0001.jpg"))
        try FileManager.default.copyItem(
            at: try TestSupport.fixtureURL("video-paired.mov"),
            to: bundle.appendingPathComponent("IMG_0001.mov"))

        // The attachment ALSO advertises plain image and movie
        // representations — enumerating those independently would
        // duplicate the asset (Codex B10). The bundle must win.
        let attachment = FakeAttachment(
            registeredTypeIdentifiers: [
                UTType.livePhoto.identifier, UTType.jpeg.identifier,
                UTType.quickTimeMovie.identifier,
            ],
            suggestedName: "IMG_0001.jpg",
            representations: [
                UTType.livePhoto.identifier: bundle,
                UTType.jpeg.identifier: try TestSupport.fixtureURL("fixture-0002.jpg"),
                UTType.quickTimeMovie.identifier: try TestSupport.fixtureURL(
                    "video-paired.mov"),
            ])
        let outcomes = await InboxWriter(store: inbox).stage(attachments: [attachment])
        guard case .staged(let manifest) = outcomes[0].status else {
            Issue.record("expected staged, got \(outcomes[0].status)")
            return
        }
        #expect(manifest.pairing == .livePhoto)
        #expect(manifest.parts.map(\.role) == [.still, .pairedVideo])
        // Exactly one item: 2 payloads + 1 manifest, no duplication.
        let files = try FileManager.default.contentsOfDirectory(
            at: inbox.inboxDir, includingPropertiesForKeys: nil)
        #expect(files.count == 3)
    }

    @Test func nonMediaAttachmentSkipsTyped() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }
        let attachment = FakeAttachment(
            registeredTypeIdentifiers: [UTType.pdf.identifier],
            suggestedName: "doc.pdf",
            representations: [:])
        let outcomes = await InboxWriter(store: inbox).stage(attachments: [attachment])
        #expect(outcomes[0].status == .skippedNotMedia)
        #expect(inbox.scan().committed.isEmpty)
    }

    @Test func loadFailureIsTypedAndCleansUp() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }
        var attachment = try jpegAttachment()
        attachment.behavior = .failLoad("provider broke")
        let outcomes = await InboxWriter(store: inbox).stage(attachments: [attachment])
        guard case .failed(.loadFailed) = outcomes[0].status else {
            Issue.record("expected loadFailed, got \(outcomes[0].status)")
            return
        }
        let scan = inbox.scan()
        #expect(scan.committed.isEmpty)
        #expect(scan.incomplete.isEmpty)
    }

    // MARK: - cancellation (Codex B8)

    @Test func cancellationMidStageCleansTyped() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }
        var slow = try jpegAttachment()
        slow.behavior = .delay(2.0)
        let writer = InboxWriter(store: inbox)
        let task = Task { await writer.stage(attachments: [slow]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let outcomes = await task.value
        guard case .failed(.cancelled) = outcomes[0].status else {
            Issue.record("expected cancelled, got \(outcomes[0].status)")
            return
        }
        let scan = inbox.scan()
        #expect(scan.committed.isEmpty)
        // Whatever partials the cancel interrupted were removed.
        #expect(scan.incomplete.isEmpty)
    }

    // MARK: - concurrent invocations (Codex B9)

    @Test func concurrentWritersNeverCollide() async throws {
        let inbox = try makeInbox()
        defer { destroy(inbox) }
        // Two extension processes staging simultaneously into one
        // inbox: collision-resistant names keep them independent.
        let attachmentA = try jpegAttachment(name: "a.jpg")
        let attachmentB = try jpegAttachment("fixture-0002.jpg", name: "b.jpg")
        async let first = InboxWriter(store: inbox).stage(attachments: [attachmentA])
        async let second = InboxWriter(store: inbox).stage(attachments: [attachmentB])
        let (a, b) = await (first, second)
        guard case .staged(let manifestA) = a[0].status,
            case .staged(let manifestB) = b[0].status
        else {
            Issue.record("expected both staged: \(a[0].status), \(b[0].status)")
            return
        }
        #expect(manifestA.itemID != manifestB.itemID)
        let scan = inbox.scan()
        #expect(scan.committed.count == 2)
        #expect(scan.incomplete.isEmpty)
        #expect(scan.malformed.isEmpty)
    }
}

import CryptoKit
import Foundation
import Testing
import VaultCore

@testable import MobileSeal

private final class BundleToken {}

enum TestSupport {
    /// KDF floor params — every test vault uses these so no test pays
    /// real Argon2id cost.
    static let fastParams = KDFParams(opslimit: 1, memlimit: 16 << 20)

    static let fastCalibration: VaultCoordinator.CalibrationRunner = { _ in
        (
            fastParams,
            KDFCalibrator.Record(
                date: Date(), chosenOpslimit: 1, chosenMemlimitMiB: 16,
                fallbackReason: "test stub", thermalState: "nominal",
                availableMemoryMiB: nil, releaseBuild: false)
        )
    }

    static func makeContainer() throws -> AppContainer {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobileseal-tests-\(UUID().uuidString)", isDirectory: true)
        return try AppContainer(base: base)
    }

    static func removeContainer(_ container: AppContainer) {
        try? FileManager.default.removeItem(
            at: container.vaultRoot.deletingLastPathComponent())
    }

    static var fixturesDir: URL {
        get throws {
            let bundle = Bundle(for: BundleToken.self)
            guard
                let url = bundle.resourceURL?.appendingPathComponent(
                    "Fixtures", isDirectory: true),
                FileManager.default.fileExists(atPath: url.path)
            else {
                throw TestError("Fixtures folder missing from test bundle")
            }
            return url
        }
    }

    static func fixtureURL(_ name: String) throws -> URL {
        let url = try fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TestError("missing fixture \(name)")
        }
        return url
    }

    /// Polls until `condition` holds (default 10 s budget).
    static func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    /// Recursive scan for a byte needle anywhere under `root` —
    /// the custody canary's search primitive.
    static func filesContaining(_ needle: [UInt8], under root: URL) -> [String] {
        var hits: [String] = []
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return hits }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: Data(needle)) != nil {
                hits.append(url.path)
            }
        }
        return hits
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension TestSupport {
    /// A full store + switchboard stack over one coordinator (CED-14):
    /// what `MobileSealApp.init` wires, with the test seams (file
    /// label key, injected defaults) in place.
    @MainActor
    static func makeStore(
        coordinator: VaultCoordinator, container: AppContainer, defaults: UserDefaults
    ) -> VaultStore {
        let labelStore = GalleryLabelStore(
            container: container,
            keyStore: FileLabelKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-label-key")))
        let switchboard = GallerySwitchboard(
            coordinator: coordinator, registry: GalleryRegistry(container: container),
            labelStore: labelStore, defaults: SendableDefaults(defaults))
        return VaultStore(
            coordinator: coordinator, container: container,
            switchboard: switchboard, labelStore: labelStore, defaults: defaults)
    }
}

/// File-backed label-key store for app-hosted tests (CED-14 WS B.2):
/// keeps each test container's label key isolated from the real
/// Keychain item. TEST ONLY — mirrors TestDeviceKeyStore.
struct FileLabelKeyStore: LabelKeyStore {
    let url: URL

    func loadKey() throws -> SymmetricKey? {
        guard let data = try? Data(contentsOf: url), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        try key.withUnsafeBytes { Data($0) }.write(to: url, options: [.atomic])
        return key
    }
}

/// File-backed device-key store for app-hosted tests (CED-13): keeps
/// each test container's device identity isolated from the real
/// Keychain item and from other parallel tests. TEST ONLY — the
/// plaintext file custody is exactly what production must never do.
struct TestDeviceKeyStore: DeviceKeyStore {
    let url: URL

    func loadOrCreateIdentity() throws -> DeviceIdentity {
        if let data = try? Data(contentsOf: url),
            data.count == DeviceIdentity.secretKeyBytes
        {
            var bytes = [UInt8](data)
            return try DeviceIdentity(consuming: SecureBytes(consumingAndZeroing: &bytes))
        }
        let secret = try DeviceIdentity.generateSecretKey()
        var out = Data(count: DeviceIdentity.secretKeyBytes)
        out.withUnsafeMutableBytes { dst in
            secret.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        try out.write(to: url, options: [.atomic])
        return try DeviceIdentity(consuming: secret)
    }
}

/// Records every sink callback; tests await conditions against it.
@MainActor
final class RecordingSink: VaultUISink {
    private(set) var phases: [VaultPhase] = []
    private(set) var unlockFailures: [UnlockFailure] = []
    private(set) var itemsHistory: [[MediaItem]] = []
    private(set) var reports: [IndexReport] = []
    private(set) var readers: [ChunkReader?] = []
    private(set) var streamingReaders: [StreamingReader?] = []
    private(set) var progress: [ImportProgress?] = []
    private(set) var summaries: [ImportSummary] = []
    private(set) var recentlyDeletedHistory: [[RecentlyDeletedItem]] = []

    var recentlyDeleted: [RecentlyDeletedItem] { recentlyDeletedHistory.last ?? [] }

    var phase: VaultPhase? { phases.last }
    var items: [MediaItem] { itemsHistory.last ?? [] }
    var currentReader: ChunkReader? { readers.last ?? nil }
    var currentStreamingReader: StreamingReader? { streamingReaders.last ?? nil }
    var lastSummary: ImportSummary? { summaries.last }

    func phaseChanged(_ phase: VaultPhase) { phases.append(phase) }
    func unlockFailed(_ failure: UnlockFailure) { unlockFailures.append(failure) }
    func itemsChanged(_ items: [MediaItem], report: IndexReport) {
        itemsHistory.append(items)
        reports.append(report)
    }
    func readerChanged(_ reader: ChunkReader?) { readers.append(reader) }
    func streamingReaderChanged(_ reader: StreamingReader?) {
        streamingReaders.append(reader)
    }
    func importProgressed(_ progress: ImportProgress?) { self.progress.append(progress) }
    func importFinished(_ summary: ImportSummary) { summaries.append(summary) }
    func recentlyDeletedChanged(_ items: [RecentlyDeletedItem]) {
        recentlyDeletedHistory.append(items)
    }
}

/// One unlocked coordinator + sink over a fresh temp container with a
/// created gallery — the common fixture for lifecycle/import tests.
@MainActor
struct UnlockedVault {
    let container: AppContainer
    let coordinator: VaultCoordinator
    let sink: RecordingSink
    static let password = "correct horse battery staple"

    static func create() async throws -> UnlockedVault {
        let container = try TestSupport.makeContainer()
        let coordinator = VaultCoordinator(
            container: container, calibration: TestSupport.fastCalibration,
            deviceKeyStore: TestDeviceKeyStore(
                url: container.deviceLocalDir.appendingPathComponent("test-device-key")),
            deviceName: "app-test-device")
        let sink = RecordingSink()
        await coordinator.attach(sink: sink)
        await coordinator.start()
        guard await TestSupport.waitUntil({ sink.phase == .needsSetup }) else {
            throw TestError("never reached needsSetup")
        }
        await coordinator.createGallery(password: password)
        guard await TestSupport.waitUntil({ sink.phase == .unlocked(importing: false) }) else {
            throw TestError("create did not reach unlocked; last=\(String(describing: sink.phase))")
        }
        return UnlockedVault(container: container, coordinator: coordinator, sink: sink)
    }

    func destroy() async {
        await coordinator.teardown()
        TestSupport.removeContainer(container)
    }
}

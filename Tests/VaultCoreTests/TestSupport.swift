import Foundation

@testable import VaultCore

/// Fast KDF parameters for tests: within the documented hard bounds
/// (floor: opslimit 1, memlimit 16 MiB) but far below the production
/// default, so each unlock costs ~10 ms instead of ~1 s.
let testKDF = KDFParams(opslimit: 1, memlimit: 16 * 1024 * 1024)

/// Minimum legal chunk size — one padding boundary — so multi-chunk
/// files stay tiny in tests.
let testChunkSize: UInt32 = 64 * 1024

/// Tiny thread-safe boolean flag (async-context-safe rendezvous).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Mutable, thread-safe fake clock for rate-limit tests.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(_ start: TimeInterval = 1_000_000) { self.time = start }

    var clock: VaultClock {
        VaultClock { [self] in
            lock.lock()
            defer { lock.unlock() }
            return time
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        time += seconds
        lock.unlock()
    }
}

struct TestVault {
    let directory: URL
    let passwordText: String
    /// This "device"'s signing identity — one per TestVault, so every
    /// test runs the real v1 signed-manifest world.
    let identity: DeviceIdentity
    let deviceName = "test-device"
    let rollbackStore: FileRollbackStateStore

    init(passwordText: String = "correct horse battery staple") throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-tests-\(UUID().uuidString)")
        self.directory = root.appendingPathComponent("gallery")
        self.passwordText = passwordText
        self.identity = try DeviceIdentity.generate()
        // Device-local state lives OUTSIDE the vault directory, as in
        // production (GOAL WS B.7).
        self.rollbackStore = FileRollbackStateStore(
            fileURL: root.appendingPathComponent("device-local/rollback.json"))
    }

    func password() throws -> SecureBytes {
        try SecureBytes(nfcNormalizedPassword: passwordText)
    }

    @discardableResult
    func create(clock: VaultClock = .system) throws -> SealedVault {
        let pw = try password()
        return try SealedVault.create(
            at: directory, password: pw, kdfParams: testKDF,
            identity: identity, deviceName: deviceName, clock: clock)
    }

    /// A pre-migration (format v0) vault — migration-suite input.
    @discardableResult
    func createV0(clock: VaultClock = .system) throws -> SealedVault {
        let pw = try password()
        return try SealedVault.createV0(
            at: directory, password: pw, kdfParams: testKDF, clock: clock)
    }

    func open(clock: VaultClock = .system) throws -> SealedVault {
        try SealedVault(directory: directory, clock: clock)
    }

    func unlock(
        clock: VaultClock = .system, acceptRollback: Bool = false
    ) throws -> UnlockSession {
        let pw = try password()
        return try open(clock: clock).unlock(
            password: pw, identity: identity, deviceName: deviceName,
            rollbackStore: rollbackStore, acceptRollback: acceptRollback)
    }

    /// Unlocks as a DIFFERENT device (its own identity + device-local
    /// state) — the restored-backup / second-device scenarios.
    func unlock(
        as identity: DeviceIdentity, named name: String,
        rollbackStore: any RollbackStateStore,
        acceptRollback: Bool = false
    ) throws -> UnlockSession {
        let pw = try password()
        return try open().unlock(
            password: pw, identity: identity, deviceName: name,
            rollbackStore: rollbackStore, acceptRollback: acceptRollback)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // -- direct disk access for corruption tests --

    var layout: VaultLayout { VaultLayout(root: directory) }

    func chunkFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: layout.chunksDir.path)
            .sorted()
            .map { layout.chunksDir.appendingPathComponent($0) }
    }

    func inventoryFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: layout.manifestDir.path)
            .sorted()
            .map { layout.manifestDir.appendingPathComponent($0) }
    }

    /// Flips one byte of the file at `url`.
    func tamper(_ url: URL, atOffset offset: Int) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        precondition(offset < bytes.count)
        bytes[offset] ^= 0xFF
        try Data(bytes).write(to: url)
    }
}

/// Per-vault-directory test identity + rollback store, so repeated
/// unlocks of the same vault behave like ONE device (as in
/// production) without every legacy call site threading identity.
final class TestUnlockContext: @unchecked Sendable {
    static let shared = TestUnlockContext()
    private let lock = NSLock()
    private var identities: [String: DeviceIdentity] = [:]
    private var stores: [String: FileRollbackStateStore] = [:]

    func context(for directory: URL) -> (DeviceIdentity, FileRollbackStateStore) {
        lock.lock()
        defer { lock.unlock() }
        let key = directory.standardizedFileURL.path
        if let identity = identities[key], let store = stores[key] {
            return (identity, store)
        }
        let identity = try! DeviceIdentity.generate()
        let store = FileRollbackStateStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "vaultcore-test-rollback-\(UInt(bitPattern: key.hashValue)).json"))
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "vaultcore-test-rollback-\(UInt(bitPattern: key.hashValue)).json"))
        identities[key] = identity
        stores[key] = store
        return (identity, store)
    }
}

extension SealedVault {
    /// Test convenience: unlock as this vault directory's cached test
    /// device (see `TestUnlockContext`).
    func unlock(password: borrowing SecureBytes) throws -> UnlockSession {
        let (identity, store) = TestUnlockContext.shared.context(for: directory)
        return try unlock(
            password: password, identity: identity, deviceName: "test-device",
            rollbackStore: store)
    }
}

func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    // Deterministic filler (splitmix64) so tests are reproducible.
    var state = seed
    var out = [UInt8]()
    out.reserveCapacity(count)
    while out.count < count {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        withUnsafeBytes(of: z.littleEndian) { out.append(contentsOf: $0) }
    }
    return Array(out.prefix(count))
}

/// Reads a whole file back through the range-read path.
func readAll(_ reader: ChunkReader, fileID: FileID, length: UInt64) throws -> [UInt8] {
    guard length > 0 else { return [] }
    return try reader.readRange(fileID: fileID, offset: 0, length: Int(length)) { bytes in
        bytes.withUnsafeBytes { Array($0) }
    }
}

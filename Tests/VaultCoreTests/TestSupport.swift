import Foundation

@testable import VaultCore

/// Fast KDF parameters for tests: within the documented hard bounds
/// (floor: opslimit 1, memlimit 16 MiB) but far below the production
/// default, so each unlock costs ~10 ms instead of ~1 s.
let testKDF = KDFParams(opslimit: 1, memlimit: 16 * 1024 * 1024)

/// Minimum legal chunk size — one padding boundary — so multi-chunk
/// files stay tiny in tests.
let testChunkSize: UInt32 = 64 * 1024

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

    init(passwordText: String = "correct horse battery staple") throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultcore-tests-\(UUID().uuidString)")
            .appendingPathComponent("gallery")
        self.passwordText = passwordText
    }

    func password() throws -> SecureBytes {
        try SecureBytes(nfcNormalizedPassword: passwordText)
    }

    @discardableResult
    func create(clock: VaultClock = .system) throws -> SealedVault {
        let pw = try password()
        return try SealedVault.create(
            at: directory, password: pw, kdfParams: testKDF, clock: clock)
    }

    func open(clock: VaultClock = .system) throws -> SealedVault {
        try SealedVault(directory: directory, clock: clock)
    }

    func unlock(clock: VaultClock = .system) throws -> UnlockSession {
        let pw = try password()
        return try open(clock: clock).unlock(password: pw)
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

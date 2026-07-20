import Foundation

/// A recorded "restored from an older backup?" acceptance (GOAL WS
/// B.7): the user re-baselined a fired rollback detector. Kept forever
/// in the device-local store — acceptance is RECORDED, never silent.
public struct RollbackAcceptance: Codable, Equatable, Sendable {
    public let galleryID: UUID
    public let signerPublicKeyHex: String
    public let presentedCounter: UInt64
    public let previousHighWaterMark: UInt64
    public let acceptedAtUnixMS: UInt64
}

/// Device-local persistence for the rollback detector's high-water
/// marks (GOAL WS B.7). Lives OUTSIDE the vault directory, beside the
/// device identity — it must neither roll back with a restored vault
/// nor ride the vault's iCloud backup (that is the point; see
/// docs/formats.md §Security notes for the reference locations).
public protocol RollbackStateStore: Sendable {
    /// Highest HEAD counter ever observed from `signer` for `gallery`,
    /// or nil if this signer has never been seen (unknown signers do
    /// not fire the detector — TOFU).
    func highWaterMark(galleryID: UUID, signer: DevicePublicKey) throws -> UInt64?
    /// Records an observation; the stored mark only ever grows.
    func recordObservation(galleryID: UUID, signer: DevicePublicKey, counter: UInt64) throws
    /// Re-baselines after user acceptance: replaces the high-water mark
    /// with the presented (older) counter and RECORDS the acceptance.
    func recordRollbackAcceptance(
        galleryID: UUID, signer: DevicePublicKey,
        presentedCounter: UInt64, previousHighWaterMark: UInt64
    ) throws
    /// All recorded acceptances for `gallery` (audit surface).
    func acceptances(galleryID: UUID) throws -> [RollbackAcceptance]
}

/// File-backed reference implementation: one JSON document per store.
/// UIKit-free; the app points it at a device-local directory that is
/// excluded from backup. Not part of the cross-platform vault format
/// (it describes THIS device's observations, not the vault).
public final class FileRollbackStateStore: RollbackStateStore, @unchecked Sendable {
    private struct State: Codable {
        // Keyed "galleryUUID/signerHex" → highest observed counter.
        var highWaterMarks: [String: UInt64] = [:]
        var acceptances: [RollbackAcceptance] = []
    }

    private let url: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.url = fileURL
    }

    private func key(_ galleryID: UUID, _ signer: DevicePublicKey) -> String {
        "\(galleryID.uuidString.lowercased())/\(signer.hex)"
    }

    private func load() throws -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        do {
            return try JSONDecoder().decode(State.self, from: data)
        } catch {
            throw VaultError.ioFailure(operation: "decode rollback state", path: url.path)
        }
    }

    private func save(_ state: State) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(state)
        } catch {
            throw VaultError.ioFailure(operation: "encode rollback state", path: url.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw VaultError.ioFailure(operation: "write rollback state", path: url.path)
        }
    }

    public func highWaterMark(galleryID: UUID, signer: DevicePublicKey) throws -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return try load().highWaterMarks[key(galleryID, signer)]
    }

    public func recordObservation(
        galleryID: UUID, signer: DevicePublicKey, counter: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = try load()
        let k = key(galleryID, signer)
        if counter > (state.highWaterMarks[k] ?? 0) {
            state.highWaterMarks[k] = counter
            try save(state)
        }
    }

    public func recordRollbackAcceptance(
        galleryID: UUID, signer: DevicePublicKey,
        presentedCounter: UInt64, previousHighWaterMark: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = try load()
        state.highWaterMarks[key(galleryID, signer)] = presentedCounter
        state.acceptances.append(
            RollbackAcceptance(
                galleryID: galleryID,
                signerPublicKeyHex: signer.hex,
                presentedCounter: presentedCounter,
                previousHighWaterMark: previousHighWaterMark,
                acceptedAtUnixMS: UInt64(Date().timeIntervalSince1970 * 1000)))
        try save(state)
    }

    public func acceptances(galleryID: UUID) throws -> [RollbackAcceptance] {
        lock.lock()
        defer { lock.unlock() }
        return try load().acceptances.filter { $0.galleryID == galleryID }
    }
}

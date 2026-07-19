import Foundation

/// BLAKE2b-256 address of a stored CAS object (chunk or inventory):
/// the hash of the FULL stored object bytes (header + ciphertext).
/// Canonical text form is 64 lowercase hex characters.
public struct ChunkAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == CryptoCore.hashBytes else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        guard let b = Hex.decode(hex), b.count == CryptoCore.hashBytes else { return nil }
        self.bytes = b
    }

    public var hex: String { Hex.encode(bytes) }
    public var description: String { hex }

    static func compute(over storedObject: [UInt8]) -> ChunkAddress {
        ChunkAddress(bytes: CryptoCore.blake2b256(storedObject))!
    }
}

/// Logical file identity inside a gallery. Random UUID minted once per
/// logical import; never reused across retries of a committed import
/// (retry after a failed commit keeps the same FileID under a new
/// transaction — see docs/formats.md §Commit protocol).
public struct FileID: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID
    public init(uuid: UUID = UUID()) { self.uuid = uuid }
    public var description: String { uuid.uuidString.lowercased() }
    var wireBytes: [UInt8] { uuid.wireBytes }
}

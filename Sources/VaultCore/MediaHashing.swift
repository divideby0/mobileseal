import Foundation

/// Public BLAKE2b-256 file hashing (CED-15 WS B.1): the share-extension
/// inbox manifest records each staged payload's hash in the vault's own
/// hash family (docs/formats.md §Algorithms), and the main app
/// re-derives it before import. Plain-bytes only — never key material;
/// the streaming form never holds the file in memory (the extension
/// runs under a 120 MB limit).
public enum MediaHashing {
    /// Streamed BLAKE2b-256 of a file's full contents, lowercase hex.
    public static func blake2b256Hex(of url: URL) throws -> String {
        try SodiumRuntime.ensure()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let stream = CryptoCore.Blake2bStream()
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            stream.update(ArraySlice([UInt8](data)))
        }
        return Self.hex(stream.finalize())
    }

    /// BLAKE2b-256 of in-memory bytes, lowercase hex.
    public static func blake2b256Hex(of data: Data) throws -> String {
        try SodiumRuntime.ensure()
        return hex(CryptoCore.blake2b256([UInt8](data)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

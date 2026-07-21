import Foundation
import Testing

@testable import VaultCore

/// CED-15: the public BLAKE2b-256 surface the share-extension inbox
/// manifests use. Pinned to the standard unkeyed 32-byte-digest test
/// vectors (RFC 7693 parameters) so the manifest hash family is
/// provably plain BLAKE2b-256 — no domain prefix, no key.
@Suite struct MediaHashingTests {
    @Test func knownVectors() throws {
        #expect(
            try MediaHashing.blake2b256Hex(of: Data("abc".utf8))
                == "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319")
        #expect(
            try MediaHashing.blake2b256Hex(of: Data())
                == "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
    }

    @Test func streamedFileHashMatchesInMemoryHash() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // Cross the 1 MiB streaming buffer boundary.
        var data = Data()
        for i in 0..<(3 << 18) {
            data.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7))
        }
        try data.write(to: url)
        #expect(
            try MediaHashing.blake2b256Hex(of: url)
                == (try MediaHashing.blake2b256Hex(of: data)))
    }
}

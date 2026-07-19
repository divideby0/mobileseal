import Foundation

/// Little-endian, bounds-checked binary codec used by every format v0
/// object. All multi-byte integers in the format are little-endian and
/// fixed-width (docs/formats.md §Conventions).
struct WireReader {
    private let bytes: [UInt8]
    private(set) var offset: Int
    let object: VaultObjectKind

    init(_ bytes: [UInt8], object: VaultObjectKind) {
        self.bytes = bytes
        self.offset = 0
        self.object = object
    }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else {
            throw VaultError.truncatedObject(object)
        }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func u8() throws -> UInt8 {
        try take(1).first!
    }

    mutating func u16() throws -> UInt16 {
        let s = try take(2)
        return s.withUnsafeBufferPointer { p in
            UInt16(p[0]) | (UInt16(p[1]) << 8)
        }
    }

    mutating func u32() throws -> UInt32 {
        let s = try take(4)
        return s.withUnsafeBufferPointer { p in
            (0..<4).reduce(UInt32(0)) { acc, i in acc | (UInt32(p[i]) << (8 * i)) }
        }
    }

    mutating func u64() throws -> UInt64 {
        let s = try take(8)
        return s.withUnsafeBufferPointer { p in
            (0..<8).reduce(UInt64(0)) { acc, i in acc | (UInt64(p[i]) << (8 * i)) }
        }
    }

    mutating func expectMagic(_ magic: [UInt8]) throws {
        let found = try? take(magic.count)
        guard let found, Array(found) == magic else {
            throw VaultError.badMagic(object)
        }
    }

    func expectExhausted() throws {
        guard remaining == 0 else {
            throw VaultError.boundsViolation(object, field: "trailing bytes")
        }
    }
}

struct WireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func raw(_ b: some Sequence<UInt8>) { bytes.append(contentsOf: b) }
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
    mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) }
    }
}

extension UUID {
    /// The 16 canonical big-endian RFC 4122 bytes.
    var wireBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }

    init(wireBytes: ArraySlice<UInt8>) throws {
        guard wireBytes.count == 16 else {
            throw VaultError.truncatedObject(.inventory)
        }
        let a = Array(wireBytes)
        self.init(uuid: (
            a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7],
            a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15]
        ))
    }
}

enum Hex {
    static func encode(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            default: return nil  // uppercase deliberately rejected: canonical form is lowercase
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append((hi << 4) | lo)
            i += 2
        }
        return out
    }
}

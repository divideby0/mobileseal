import Clibsodium
import Foundation
import VaultCore

// Argon2id unlock-timing benchmark (CED-10 WS B.5, green gate 8).
//
// Reports HONEST macOS numbers for the stored-parameter candidates.
// The 0.5–1 s device envelope from intake §5.1 is asserted on real
// hardware at the App Shell leg, where a device target first exists
// (Codex B13); nothing here claims device timing.
//
// The benchmark measures crypto_pwhash directly (the KDF dominates
// unlock cost; DEK unwrap adds one AEAD open over 48 bytes), then
// measures one full SealedVault.create + unlock round with the
// production default for an end-to-end sanity number.

extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &chars, &size, nil, 0)
        return String(cString: chars)
    }
}

guard sodium_init() >= 0 else {
    fatalError("sodium_init failed")
}

struct Candidate {
    let label: String
    let opslimit: UInt64
    let memlimitBytes: Int
}

let candidates: [Candidate] = [
    Candidate(label: "INTERACTIVE (2 ops, 64 MiB)", opslimit: 2, memlimitBytes: 64 << 20),
    Candidate(label: "opslimit 3, 128 MiB", opslimit: 3, memlimitBytes: 128 << 20),
    Candidate(label: "MODERATE - DEFAULT (3 ops, 256 MiB)", opslimit: 3, memlimitBytes: 256 << 20),
    Candidate(label: "opslimit 3, 384 MiB", opslimit: 3, memlimitBytes: 384 << 20),
    Candidate(label: "opslimit 3, 512 MiB", opslimit: 3, memlimitBytes: 512 << 20),
]

let password = Array("benchmark password - not a secret".utf8)
let salt: [UInt8] = {
    var s = [UInt8](repeating: 0, count: Int(crypto_pwhash_SALTBYTES))
    randombytes_buf(&s, s.count)
    return s
}()

func timeOnce(_ c: Candidate, password: [UInt8], salt: [UInt8]) -> TimeInterval {
    var key = [UInt8](repeating: 0, count: 32)
    let start = DispatchTime.now()
    let rc = password.withUnsafeBufferPointer { pw in
        crypto_pwhash(
            &key, 32,
            UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: CChar.self),
            UInt64(pw.count), salt, c.opslimit, c.memlimitBytes,
            crypto_pwhash_ALG_ARGON2ID13)
    }
    let end = DispatchTime.now()
    guard rc == 0 else { fatalError("crypto_pwhash failed (memlimit \(c.memlimitBytes))") }
    return TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

print("Argon2id (crypto_pwhash, ALG_ARGON2ID13) - macOS, \(ProcessInfo.processInfo.machineHardwareName)")
print("runs: 1 warmup + 5 measured; times in seconds\n")
print(pad("parameters", 38) + pad("min", 9) + pad("median", 9) + "max")

for candidate in candidates {
    _ = timeOnce(candidate, password: password, salt: salt)  // warmup
    let times = (0..<5).map { _ in timeOnce(candidate, password: password, salt: salt) }.sorted()
    let row =
        pad(candidate.label, 38)
        + pad(String(format: "%.3f", times.first!), 9)
        + pad(String(format: "%.3f", times[times.count / 2]), 9)
        + String(format: "%.3f", times.last!)
    print(row)
}

// End-to-end: create + unlock with the production default. (Wrapped
// in a function — top-level move-only bindings are borrowed globals
// and cannot be consumed by lock().)
func endToEndUnlockSeconds() throws -> TimeInterval {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("argon2-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let pw = try SecureBytes(nfcNormalizedPassword: "benchmark password - not a secret")
    let created = try SealedVault.create(at: dir, password: pw, kdfParams: .default)
    let pw2 = try SecureBytes(nfcNormalizedPassword: "benchmark password - not a secret")
    let start = DispatchTime.now()
    let session = try created.unlock(password: pw2)
    let end = DispatchTime.now()
    session.lock()
    return TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
}

let unlockSeconds = try endToEndUnlockSeconds()
print(String(format: "\nfull SealedVault.unlock with defaults (3 ops, 256 MiB): %.3f s", unlockSeconds))

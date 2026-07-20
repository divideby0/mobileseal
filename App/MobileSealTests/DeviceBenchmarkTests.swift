import Foundation
import Testing
import VaultCore

@testable import MobileSeal

/// Gate 6 — the device Argon2id benchmark, runnable as a single test
/// on a real iPhone:
///
///     xcodebuild test -project MobileSeal.xcodeproj -scheme MobileSeal \
///       -destination 'platform=iOS,id=<device-udid>' \
///       -only-testing:MobileSealTests/DeviceBenchmarkTests
///
/// Runs the REAL calibrate-at-creation protocol (median-of-5 unlocks
/// per candidate, thermal + 2× headroom gates, peak-footprint
/// sampling) and prints the record as `DEVICE-BENCHMARK <json>` for
/// RESULT.md. Skipped on the simulator — its numbers are the host's,
/// not a phone's (Codex A7).
@Suite struct DeviceBenchmarkTests {
    static var isDevice: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            return true
        #endif
    }

    @Test(.enabled(if: isDevice)) func deviceCalibration() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-benchmark-\(UUID().uuidString)", isDirectory: true)
        let (params, record) = KDFCalibrator.calibrate(scratchDir: scratch)

        let json = try JSONEncoder().encode(record)
        print("DEVICE-BENCHMARK \(String(decoding: json, as: UTF8.self))")

        // The chosen params must be a documented candidate with a
        // recorded median; the envelope claim (0.5–1.0 s) is asserted
        // when calibration measured (a thermal fallback records why
        // it did not).
        #expect(KDFCalibrator.ladder.contains(params))
        if record.fallbackReason == nil || record.fallbackReason?.contains("floor stands") == true
        {
            let median = record.medians[KDFCalibrator.label(params)]
            #expect(median != nil, "chosen params have no recorded median")
        }
        #expect(record.peakFootprintMiB != nil, "peak footprint must be sampled on device")
    }
}

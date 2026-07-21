import Foundation
import VaultCore

#if os(iOS)
    import os
#endif

/// Device Argon2id calibration, calibrate-at-creation (GOAL WS D.4,
/// Codex B6): VaultCore has no rewrap API, so parameters are chosen
/// ONCE, before `SealedVault.create`. Protocol:
///
///  1. Refuse to raise above MODERATE unless thermal state is nominal/
///     fair and measured memory headroom ≥ 2× the candidate memlimit.
///  2. Measure MODERATE (3 ops / 256 MiB) as median-of-5 real unlocks
///     against a throwaway vault (unlock time ≈ KDF time).
///  3. Extrapolate linearly in memlimit across the candidate ladder
///     (Argon2id time scales ~linearly with memory at fixed ops),
///     pick the largest candidate predicted inside the 0.5–1.0 s
///     envelope, then VERIFY the pick with its own median-of-5.
///  4. Any gate failing → fall back to MODERATE, reason recorded.
///
/// The record (candidates, medians, thermal, headroom, build type) is
/// persisted for RESULT.md's device-benchmark gate.
enum KDFCalibrator {
    static let envelope: ClosedRange<TimeInterval> = 0.5...1.0
    static let moderate = KDFParams(opslimit: 3, memlimit: 256 << 20)
    /// Candidate ladder (research: argon2id-tuning-on-modern-iphones —
    /// raise memlimit before opslimit).
    static let ladder: [KDFParams] = [
        KDFParams(opslimit: 3, memlimit: 256 << 20),
        KDFParams(opslimit: 3, memlimit: 384 << 20),
        KDFParams(opslimit: 3, memlimit: 512 << 20),
    ]

    struct Record: Codable, Equatable, Sendable {
        var date: Date
        /// "3ops/256MiB" → median seconds.
        var medians: [String: TimeInterval] = [:]
        var chosenOpslimit: UInt32
        var chosenMemlimitMiB: UInt64
        var fallbackReason: String?
        var thermalState: String
        var availableMemoryMiB: Int64?
        /// Peak process physical footprint sampled across the timed
        /// unlocks (GOAL WS D.4 requires peak memory recorded; nil on
        /// injected-measurement test runs).
        var peakFootprintMiB: Int64? = nil
        var releaseBuild: Bool
    }

    static func label(_ p: KDFParams) -> String {
        "\(p.opslimit)ops/\(p.memlimit >> 20)MiB"
    }

    /// Runs the calibration protocol. `scratchDir` receives a
    /// throwaway vault (removed before return); `measure` is the
    /// injectable timing seam so unit tests can feed synthetic
    /// timings without multi-second KDF runs.
    static func calibrate(
        scratchDir: URL,
        measure: ((KDFParams, URL) throws -> TimeInterval)? = nil,
        headroom: Int64? = availableMemoryBytes(),
        thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> (KDFParams, Record) {
        // Real runs sample peak footprint across the measurements;
        // injected test measurements skip the sampler.
        let sampler = measure == nil ? FootprintSampler() : nil
        let measure = measure ?? Self.realMedianOf5
        defer { sampler?.stop() }
        var record = Record(
            date: Date(),
            chosenOpslimit: moderate.opslimit,
            chosenMemlimitMiB: moderate.memlimit >> 20,
            thermalState: thermalStateName(thermal),
            availableMemoryMiB: headroom.map { $0 >> 20 },
            releaseBuild: isReleaseBuild)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        func fallback(_ reason: String) -> (KDFParams, Record) {
            record.fallbackReason = reason
            record.chosenOpslimit = moderate.opslimit
            record.chosenMemlimitMiB = moderate.memlimit >> 20
            record.peakFootprintMiB = sampler?.peakBytes.map { $0 >> 20 }
            return (moderate, record)
        }

        // Gate: thermal — fires before any measurement, so no raise
        // is attempted (wave-001 coderabbit: the old copy blamed
        // "headroom" for a thermal decision).
        guard thermal == .nominal || thermal == .fair else {
            return fallback(
                "thermal state \(thermalStateName(thermal)) — raise not attempted")
        }

        // Measure MODERATE.
        let baseMedian: TimeInterval
        do {
            baseMedian = try measure(moderate, scratchDir)
            record.medians[label(moderate)] = baseMedian
        } catch {
            return fallback("measurement failed: \(error)")
        }

        // Pick the largest candidate predicted ≤ envelope upper bound
        // with 2× memory headroom.
        var pick = moderate
        var predicted = baseMedian
        for candidate in ladder.dropFirst() {
            let scale = Double(candidate.memlimit) / Double(moderate.memlimit)
            let estimate = baseMedian * scale
            guard estimate <= envelope.upperBound else { break }
            if let headroom, headroom < Int64(candidate.memlimit) * 2 { break }
            if headroom == nil { break }  // unknown headroom — don't raise
            pick = candidate
            predicted = estimate
        }

        guard pick != moderate else {
            record.fallbackReason =
                baseMedian > envelope.upperBound
                ? "MODERATE median \(String(format: "%.3f", baseMedian))s already above envelope — floor stands"
                : nil
            record.peakFootprintMiB = sampler?.peakBytes.map { $0 >> 20 }
            return (moderate, record)
        }

        // Verify the pick with its own median-of-5.
        do {
            let verified = try measure(pick, scratchDir)
            record.medians[label(pick)] = verified
            guard verified <= envelope.upperBound else {
                return fallback(
                    "verified \(label(pick)) median \(String(format: "%.3f", verified))s exceeds envelope (predicted \(String(format: "%.3f", predicted))s)"
                )
            }
            record.chosenOpslimit = pick.opslimit
            record.chosenMemlimitMiB = pick.memlimit >> 20
            record.peakFootprintMiB = sampler?.peakBytes.map { $0 >> 20 }
            return (pick, record)
        } catch {
            return fallback("verification failed: \(error)")
        }
    }

    /// Real measurement: throwaway vault INSIDE the caller's scratch
    /// directory (the Data-Protection-classed container — wave-001
    /// claude-code #6 caught the seam being ignored), one create,
    /// five timed unlocks, median.
    static func realMedianOf5(_ params: KDFParams, scratchDir: URL) throws -> TimeInterval {
        let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Throwaway scratch passphrase — the vault is deleted before
        // return; every timed unlock SUCCEEDS so the rate limiter
        // resets each round and the timing is the honest KDF cost.
        let passphrase = "mobileseal-calibration-\(UUID().uuidString)"
        // Throwaway identity + rollback state, deleted with the vault:
        // calibration must never touch the real device key or the
        // device-local high-water store.
        let identity = try DeviceIdentity.generate()
        let rollback = FileRollbackStateStore(
            fileURL: dir.appendingPathComponent("calibration-rollback.json"))
        let vault: SealedVault
        do {
            let password = try SecureBytes(nfcNormalizedPassword: passphrase)
            vault = try SealedVault.create(
                at: dir, password: password, kdfParams: params,
                identity: identity, deviceName: "calibration")
        }

        var timings: [TimeInterval] = []
        for _ in 0..<5 {
            let pw = try SecureBytes(nfcNormalizedPassword: passphrase)
            let start = ContinuousClock.now
            let session = try vault.unlock(
                password: pw, identity: identity, deviceName: "calibration",
                rollbackStore: rollback)
            let elapsed = start.duration(to: .now)
            session.lock(drainDeadline: 0)
            timings.append(
                Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18)
        }
        return timings.sorted()[timings.count / 2]
    }

    // MARK: - peak-footprint sampling (GOAL WS D.4: peak memory
    // recorded alongside the calibration medians)

    /// Samples the process physical footprint (`task_vm_info.
    /// phys_footprint`) every 25 ms on a utility thread and keeps the
    /// maximum observed across the calibration run.
    final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak: Int64 = 0

        init() {
            let thread = Thread { [weak self] in
                while true {
                    guard let self else { return }
                    self.lock.lock()
                    let live = self.running
                    if let sample = Self.currentFootprint() {
                        self.peak = max(self.peak, sample)
                    }
                    self.lock.unlock()
                    if !live { return }
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
            thread.qualityOfService = .utility
            thread.start()
        }

        var peakBytes: Int64? {
            lock.lock()
            defer { lock.unlock() }
            return peak > 0 ? peak : nil
        }

        func stop() {
            lock.lock()
            running = false
            lock.unlock()
        }

        static func currentFootprint() -> Int64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return Int64(info.phys_footprint)
        }
    }

    // MARK: - environment probes

    static var isReleaseBuild: Bool {
        #if DEBUG
            return false
        #else
            return true
        #endif
    }

    static func thermalStateName(
        _ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Real free-memory headroom on iOS devices; nil where the probe
    /// is meaningless (simulator reports the host's memory model).
    static func availableMemoryBytes() -> Int64? {
        #if os(iOS) && !targetEnvironment(simulator)
            return Int64(os_proc_available_memory())
        #else
            return nil
        #endif
    }
}

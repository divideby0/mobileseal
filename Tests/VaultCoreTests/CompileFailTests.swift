import Foundation
import Testing

@testable import VaultCore

/// The compile-fail misuse harness (WS A.3, Codex A3): each negative
/// fixture must FAIL to compile with its expected, stable diagnostic —
/// and each is paired with a positive-compilation control of the same
/// shape minus the misuse, so a fixture can never "pass" because of an
/// unrelated breakage (wrong include path, syntax rot, toolchain
/// drift). Runs the pinned toolchain's swiftc with `-emit-sil` (the
/// move-only ownership diagnostics are SIL-pass diagnostics;
/// `-typecheck` would not surface them).
@Suite(.serialized) struct CompileFailHarness {
    struct Fixture: Sendable, CustomStringConvertible {
        let name: String
        /// Expected diagnostic substring; nil = positive control that
        /// must compile clean.
        let expectedDiagnostic: String?
        var description: String { name }
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "use-after-lock", expectedDiagnostic: "'session' used after consume"),
        Fixture(name: "use-after-lock-control", expectedDiagnostic: nil),
        Fixture(name: "double-lock", expectedDiagnostic: "'session' consumed more than once"),
        Fixture(name: "double-lock-control", expectedDiagnostic: nil),
        Fixture(name: "securebytes-copy", expectedDiagnostic: "'bytes' consumed more than once"),
        Fixture(name: "securebytes-copy-control", expectedDiagnostic: nil),
        Fixture(
            name: "securebytes-consume-while-borrowed",
            expectedDiagnostic: "requires exclusive access"),
        Fixture(name: "securebytes-consume-while-borrowed-control", expectedDiagnostic: nil),
        Fixture(
            name: "session-task-capture",
            expectedDiagnostic: "cannot be consumed when captured by an escaping closure"),
        Fixture(name: "session-task-capture-control", expectedDiagnostic: nil),
        Fixture(
            name: "devicekey-raw-escape",
            expectedDiagnostic: "'secretKey' is inaccessible due to 'private' protection level"),
        Fixture(name: "devicekey-raw-escape-control", expectedDiagnostic: nil),
    ]

    @Test(arguments: fixtures)
    func fixture(_ fixture: Fixture) throws {
        let paths = try Paths()
        let fixtureURL = paths.fixturesDir.appendingPathComponent("\(fixture.name).swift")
        #expect(
            FileManager.default.fileExists(atPath: fixtureURL.path),
            "fixture source missing: \(fixtureURL.path)")

        let (status, output) = try runSwiftc(fixtureURL: fixtureURL, paths: paths)

        if let expected = fixture.expectedDiagnostic {
            #expect(status != 0, "\(fixture.name): misuse fixture unexpectedly compiled")
            #expect(
                output.contains(expected),
                "\(fixture.name): expected diagnostic \"\(expected)\" not found in:\n\(output)")
        } else {
            #expect(status == 0, "\(fixture.name): control failed to compile:\n\(output)")
        }
    }

    /// Every negative fixture must have its positive control on disk
    /// (the pairing rule itself is enforced, not just convention).
    @Test func everyMisuseHasAControl() {
        let negatives = Self.fixtures.filter { $0.expectedDiagnostic != nil }.map(\.name)
        let controls = Set(Self.fixtures.filter { $0.expectedDiagnostic == nil }.map(\.name))
        for negative in negatives {
            #expect(
                controls.contains("\(negative)-control"),
                "misuse fixture \(negative) has no positive control")
        }
    }

    // MARK: - toolchain plumbing

    struct Paths {
        let fixturesDir: URL
        let modulesDir: URL
        let clibsodiumHeaders: URL

        init() throws {
            let thisFile = URL(fileURLWithPath: #filePath)
            let testsDir = thisFile.deletingLastPathComponent()  // Tests/VaultCoreTests
            fixturesDir = testsDir.appendingPathComponent("CompileFail/Fixtures")
            let packageRoot = testsDir
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // package root

            // The built VaultCore module sits beside the test bundle.
            let debugDir = Bundle.module.bundleURL.deletingLastPathComponent()
            modulesDir = debugDir.appendingPathComponent("Modules")
            guard
                FileManager.default.fileExists(
                    atPath: modulesDir.appendingPathComponent("VaultCore.swiftmodule").path)
            else {
                throw VaultError.ioFailure(
                    operation: "locate VaultCore.swiftmodule", path: modulesDir.path)
            }

            // Clibsodium's macOS headers inside the checked-out
            // xcframework (slice name is stable for macOS).
            let xcframework = packageRoot.appendingPathComponent(
                ".build/checkouts/swift-sodium/Clibsodium.xcframework")
            let slices = (try? FileManager.default.contentsOfDirectory(atPath: xcframework.path))
                ?? []
            guard let macSlice = slices.first(where: { $0.hasPrefix("macos-") }) else {
                throw VaultError.ioFailure(operation: "locate Clibsodium slice", path: xcframework.path)
            }
            clibsodiumHeaders = xcframework.appendingPathComponent("\(macSlice)/Headers")
        }
    }

    private func runSwiftc(fixtureURL: URL, paths: Paths) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-emit-sil", "-o", "/dev/null",
            fixtureURL.path,
            "-I", paths.modulesDir.path,
            "-I", paths.clibsodiumHeaders.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe BEFORE waiting: a diagnostic-heavy fixture
        // filling the pipe buffer while we wait would deadlock the
        // suite (wave-001 coderabbit).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

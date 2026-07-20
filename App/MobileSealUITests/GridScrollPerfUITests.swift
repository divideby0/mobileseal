import XCTest

/// Gate 3 — instrumented scroll over a 500-photo fixture gallery on
/// the simulator, with hitch/dropped-frame metrics recorded and
/// thresholds stated here.
///
/// Instrumentation: the grid runs a CADisplayLink while scrolling (in
/// UI-test mode) and reports `frames`, `hitches` (a frame arriving
/// > 8.4 ms — one 120 Hz interval — past its promised
/// `targetTimestamp`; lateness-vs-target tracks ProMotion's adaptive
/// refresh rate, which a naive interval heuristic misreads as
/// hitching), and `maxGapMs` (worst lateness) through its
/// accessibility value; an os_signpost interval ("grid-scroll")
/// brackets each scroll for Instruments. Thresholds (stated per the
/// gate):
///
///   - hitch ratio ≤ 10% of frames across the deceleration scrolls
///     (simulator rendering is not device rendering — Codex A7 — the
///     device spot-check in RESULT.md carries the real-hardware
///     number);
///   - no frame ≥ 250 ms late (a visible stall).
final class GridScrollPerfUITests: XCTestCase {
    private let password = "perf vault password"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testScroll500PhotoGalleryHitchMetrics() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mobileseal-uitest",
            "-mobileseal-uitest-container", "perf-\(UUID().uuidString.prefix(8))",
            "-mobileseal-uitest-reset", "1",
            // Seeding 500 items takes minutes with no user interaction
            // — the 5-minute idle backstop would (correctly) lock the
            // vault mid-seed. Launch-argument defaults disable it for
            // this measurement run only.
            "-lock.idleTimeoutSeconds", "0",
        ]
        app.launch()

        // Create the vault.
        let passwordField = app.secureTextFields["setup-password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        passwordField.tap()
        passwordField.typeText(password)
        let confirmField = app.secureTextFields["setup-confirm"]
        confirmField.tap()
        confirmField.typeText(password)
        app.buttons["setup-create"].tap()

        // Seed 500 items directly through the Gallery actor.
        let seed = app.buttons["seed-gallery-button"]
        XCTAssertTrue(seed.waitForExistence(timeout: 60))
        seed.tap()

        // Seeding runs asynchronously (≈1000 WAL commits); the
        // toolbar's item-count element is the completion signal —
        // visible cell counts cannot observe off-screen population.
        let count = app.staticTexts["item-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 30))
        let deadline = Date().addingTimeInterval(540)
        while Date() < deadline, count.label != "500" {
            Thread.sleep(forTimeInterval: 5)
        }
        XCTAssertEqual(count.label, "500", "seed did not reach 500 items in time")

        let grid = app.collectionViews["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))

        // Instrumented scroll: several fast swipes (drag + fling),
        // letting deceleration finish so the display link captures
        // full scroll intervals.
        var totalFrames = 0
        var totalHitches = 0
        var worstGap = 0.0
        for _ in 0..<6 {
            grid.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.5)
            if let report = grid.value as? String {
                let metrics = Self.parse(report)
                totalFrames += metrics.frames
                totalHitches += metrics.hitches
                worstGap = max(worstGap, metrics.maxGapMs)
            }
        }

        XCTAssertGreaterThan(totalFrames, 0, "no frames recorded — instrumentation dead")
        let hitchRatio = Double(totalHitches) / Double(totalFrames)
        // Thresholds stated above.
        XCTAssertLessThanOrEqual(
            hitchRatio, 0.10,
            "hitch ratio \(hitchRatio) over \(totalFrames) frames (hitches=\(totalHitches))")
        XCTAssertLessThan(
            worstGap, 250,
            "worst frame gap \(worstGap) ms — visible stall")

        // Record the numbers in the test log for RESULT.md.
        print(
            "PERF-REPORT frames=\(totalFrames) hitches=\(totalHitches) hitchRatio=\(hitchRatio) maxGapMs=\(worstGap)"
        )
    }

    private static func parse(_ report: String) -> (frames: Int, hitches: Int, maxGapMs: Double) {
        var frames = 0
        var hitches = 0
        var maxGap = 0.0
        for token in report.split(separator: " ") {
            let pair = token.split(separator: "=")
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "frames": frames = Int(pair[1]) ?? 0
            case "hitches": hitches = Int(pair[1]) ?? 0
            case "maxGapMs": maxGap = Double(pair[1]) ?? 0
            default: break
            }
        }
        return (frames, hitches, maxGap)
    }
}

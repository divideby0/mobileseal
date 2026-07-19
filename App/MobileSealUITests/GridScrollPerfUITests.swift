import XCTest

/// Gate 3 — instrumented scroll over a 500-photo fixture gallery on
/// the simulator, with hitch/dropped-frame metrics recorded and
/// thresholds stated here.
///
/// Instrumentation: the grid runs a CADisplayLink while scrolling (in
/// UI-test mode) and reports `frames`, `hitches` (frame gap > 1.5×
/// refresh interval), and `maxGapMs` through its accessibility value;
/// an os_signpost interval ("grid-scroll") brackets each scroll for
/// Instruments sessions. Thresholds (stated per the gate):
///
///   - hitch ratio ≤ 10% of frames across the deceleration scrolls
///     (simulator rendering is not device rendering — Codex A7 — the
///     device spot-check in RESULT.md carries the real-hardware
///     number);
///   - no single frame gap ≥ 250 ms (a visible stall).
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

        let grid = app.otherElements["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        // Seeding runs asynchronously; wait for the full population by
        // polling the diffable snapshot through the cell count climb.
        let deadline = Date().addingTimeInterval(300)
        var settled = false
        while Date() < deadline {
            if app.cells.count >= 400 || grid.descendants(matching: .cell).count >= 400 {
                settled = true
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }
        // Cell counts only report on-screen cells for collection
        // views; fall back to time-based settling.
        if !settled { Thread.sleep(forTimeInterval: 10) }

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

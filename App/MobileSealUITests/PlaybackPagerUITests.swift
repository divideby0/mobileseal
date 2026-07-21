import XCTest

/// CED-12 gate 4 — prefetch discipline under fast swipes across a
/// mixed batch: the one-active-player invariant holds (players ≤ 1,
/// instrumented), generation tokens cancel stale warm work (no
/// runaway requests), and cache bytes stay ≤ the budget throughout.
/// Counters come from the pager's UI-test-only `playback-debug`
/// overlay, refreshed from the PlaybackController's real registers.
final class PlaybackPagerUITests: XCTestCase {
    private let password = "pager vault password 9"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private struct DebugCounters {
        let players: Int
        let requests: Int
        let cacheBytes: Int
        let budget: Int
        let activations: Int
        let warms: Int
        let warmsCancelled: Int
        let warmsInFlight: Int

        init?(_ raw: String) {
            var values: [String: Int] = [:]
            for pair in raw.split(separator: " ") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2, let v = Int(kv[1]) else { return nil }
                values[String(kv[0])] = v
            }
            guard let p = values["players"], let r = values["requests"],
                let c = values["cacheBytes"], let b = values["budget"],
                let a = values["activations"], let w = values["warms"],
                let wc = values["warmsCancelled"], let wf = values["warmsInFlight"]
            else { return nil }
            players = p
            requests = r
            cacheBytes = c
            budget = b
            activations = a
            warms = w
            warmsCancelled = wc
            warmsInFlight = wf
        }
    }

    private func readCounters(_ app: XCUIApplication) -> DebugCounters? {
        let label = app.staticTexts["playback-debug"]
        guard label.exists, let raw = label.value as? String else { return nil }
        return DebugCounters(raw)
    }

    func testFastSwipesKeepOnePlayerAndBudget() throws {
        let container = "pager-\(UUID().uuidString.prefix(8))"
        let app = XCUIApplication()
        app.launchArguments = [
            "-mobileseal-uitest",
            "-mobileseal-uitest-container", container,
            "-mobileseal-uitest-reset", "1",
        ]
        app.launch()

        // Create + import the mixed fixture batch (images, Live Photo
        // pair, both moov variants, unsupported codec, corrupt last).
        let passwordField = app.secureTextFields["setup-password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        passwordField.tap()
        passwordField.typeText(password)
        let confirmField = app.secureTextFields["setup-confirm"]
        confirmField.tap()
        confirmField.typeText(password)
        app.buttons["setup-create"].tap()

        XCTAssertTrue(app.tapMoreMenuItem(label: "Import Fixtures", timeout: 60))
        let summary = app.otherElements["import-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 600), "import never finished")
        app.buttons["summary-done"].tap()

        // Open the pager at the top of the grid (corrupt item), then
        // swipe FAST through the mixed head of the batch: unsupported
        // video → tail-moov video → fast-start video → images.
        let grid = app.collectionViews["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        grid.cells.element(boundBy: 0).tap()
        let pagerClose = app.buttons["pager-close"]
        XCTAssertTrue(pagerClose.waitForExistence(timeout: 15), "pager never opened")

        // Eight rapid swipes with no settling time between them.
        for _ in 0..<8 {
            app.swipeLeft()
        }

        // Let the landed page settle, then assert the invariants.
        let debugLabel = app.staticTexts["playback-debug"]
        XCTAssertTrue(debugLabel.waitForExistence(timeout: 10), "debug overlay missing")
        var worstPlayers = 0
        var worstOverBudget = false
        var last: DebugCounters?
        let deadline = Date().addingTimeInterval(6)
        var samples = 0
        while Date() < deadline {
            if let counters = readCounters(app) {
                samples += 1
                worstPlayers = max(worstPlayers, counters.players)
                if counters.cacheBytes > counters.budget { worstOverBudget = true }
                last = counters
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertGreaterThan(samples, 0, "no counter samples read")
        XCTAssertLessThanOrEqual(worstPlayers, 1, "one-active-player violated")
        XCTAssertFalse(worstOverBudget, "cache bytes exceeded the residency budget")

        // NON-tautological observables (wave-001 claude-code #5):
        // player-item creations are bounded by landings — 8 swipes +
        // the opening landing + settle slack — and stale warm work is
        // actually CANCELLED (tracked tasks; in-flight drains).
        let settled = try XCTUnwrap(last, "no final counter sample")
        XCTAssertLessThanOrEqual(
            settled.activations, 10,
            "more player activations (\(settled.activations)) than landings — one-active-player discipline broken")
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                (readCounters(app)?.warmsInFlight ?? 99) == 0
            }, "stale warm tasks never drained after the swipe burst")
        // Warming actually ran during the burst. Whether any warm was
        // CANCELLED here is timing-dependent (the tiny fixtures warm
        // in milliseconds, so most complete before the next landing);
        // the cancellation mechanism itself is pinned
        // deterministically at unit level (warmAbandonsWhenCancelled,
        // warmTasksAreTrackedAndSweptByLock).
        XCTAssertGreaterThan(settled.warms, 0, "no neighbor warming ran during the burst")

        // Swipe back toward the head of the batch until a VIDEO page
        // lands and confirm playback activates for the landed item
        // (players becomes 1) — bounded, order-agnostic.
        var activated = false
        for _ in 0..<10 where !activated {
            app.swipeRight()
            activated = waitUntil(timeout: 3) {
                (readCounters(app)?.players ?? 0) == 1
            }
        }
        XCTAssertTrue(activated, "no landed video ever activated its player")

        // Requests drain once the landed item is served.
        let drained = waitUntil(timeout: 15) {
            (readCounters(app)?.requests ?? 99) == 0
        }
        XCTAssertTrue(drained, "loader requests never drained after landing")

        app.buttons["pager-close"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}

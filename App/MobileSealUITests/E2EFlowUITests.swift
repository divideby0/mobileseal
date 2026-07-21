import XCTest

/// Gate 2 — the scripted end-to-end on simulator: create gallery →
/// import the committed fixture batch (112 mixed HEIC/JPEG + 1 forced
/// failure, ≥100) through the real pipeline (fixture provider seam;
/// the system picker gets a manual device smoke test) → grid renders
/// from encrypted thumbnails → relaunch → unlock → grid restores →
/// per-item failure visible.
final class E2EFlowUITests: XCTestCase {
    private let password = "e2e vault password 42"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Polls `condition` (XCUIElement queries re-evaluate on read).
    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func launch(container: String, fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mobileseal-uitest",
            "-mobileseal-uitest-container", container,
        ]
        if fresh {
            app.launchArguments.append(contentsOf: ["-mobileseal-uitest-reset", "1"])
        }
        app.launch()
        return app
    }

    func testCreateImportRelaunchUnlockRestore() throws {
        let container = "e2e-\(UUID().uuidString.prefix(8))"
        var app = launch(container: container, fresh: true)

        // --- Create the gallery.
        let passwordField = app.secureTextFields["setup-password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "setup screen never appeared")
        passwordField.tap()
        passwordField.typeText(password)
        let confirmField = app.secureTextFields["setup-confirm"]
        confirmField.tap()
        confirmField.typeText(password)
        app.buttons["setup-create"].tap()

        // --- Import the committed fixture batch (seam in the More
        // menu — the toolbar keeps exactly two trailing items).
        XCTAssertTrue(
            app.tapMoreMenuItem(label: "Import Fixtures", timeout: 60),
            "gallery (unlocked) never appeared after create")

        // 112 healthy images (first carries the Live Photo pair) + 3
        // videos (fast-start MP4, tail-moov MOV, unsupported-codec
        // MP4) + 1 corrupt (last): the summary sheet marks completion.
        let summary = app.otherElements["import-summary"]
        let summaryShown = summary.waitForExistence(timeout: 600)
        XCTAssertTrue(summaryShown, "import summary never appeared")

        // Failure visible in the summary (forced per-item failure):
        // 115 imported (incl. both moov variants + the unsupported-
        // but-authentic codec, plus CED-16's embedded-thumbnail
        // stills), the corrupt last item failed.
        let line = app.staticTexts["summary-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        XCTAssertEqual(
            line.label, "imported=115 skipped=0 failed=1 interrupted=false",
            "batch summary mismatch")
        app.buttons["summary-done"].tap()

        // --- Grid renders from encrypted thumbnails.
        let grid = app.collectionViews["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "grid never appeared")
        XCTAssertTrue(
            app.cells.count > 0 || grid.descendants(matching: .any).count > 0,
            "grid rendered no cells")

        // --- Videos show poster + DURATION in the grid (gate 2).
        let durationBadge = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'video-duration-'")
        ).firstMatch
        XCTAssertTrue(
            durationBadge.waitForExistence(timeout: 15),
            "no video duration badge in the grid")

        // Cells are selected by SEMANTIC value, not grid position
        // (XCUITest cell order is not reliably the sort order).
        // --- Unsupported-but-authentic codec: its OWN state, never
        // the damaged badge (Codex A6).
        let unsupportedCell = grid.cells.matching(
            NSPredicate(format: "value == 'video no preview'")
        ).firstMatch
        XCTAssertTrue(
            unsupportedCell.waitForExistence(timeout: 15),
            "unsupported-video cell not found")
        unsupportedCell.tap()
        // The pager's container view is plain UIKit; anchor on its
        // close button (buttons always surface to XCUITest).
        let pagerClose = app.buttons["pager-close"]
        XCTAssertTrue(pagerClose.waitForExistence(timeout: 15), "pager never opened")
        let state = app.staticTexts["playback-state"]
        let stateAppeared = state.waitForExistence(timeout: 20)
        if !stateAppeared {
            print("E2EDBG tree-begin")
            print(app.debugDescription)
            print("E2EDBG tree-end")
        }
        XCTAssertTrue(stateAppeared, "unsupported-codec state never appeared")
        XCTAssertTrue(
            state.label.contains("Can't play"),
            "expected can't-play copy, got: \(state.label)")
        app.buttons["pager-close"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))

        // --- Autoplay muted on landing, tap unmutes, scrub to three
        // positions (gate 2) — the first playable-video cell (the
        // newest: tail-moov MOV).
        let videoCells = grid.cells.matching(NSPredicate(format: "value == 'video'"))
        XCTAssertTrue(
            videoCells.firstMatch.waitForExistence(timeout: 15),
            "no playable-video cell found")
        videoCells.element(boundBy: 0).tap()
        XCTAssertTrue(pagerClose.waitForExistence(timeout: 15), "pager never opened on video")
        let mute = app.buttons["mute-toggle"]
        XCTAssertTrue(mute.waitForExistence(timeout: 20), "video chrome never appeared")
        XCTAssertEqual(mute.value as? String, "muted", "autoplay must start muted")

        // Autoplay is observable: the scrubber advances by itself.
        let scrubber = app.sliders["video-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let initial = scrubber.normalizedSliderPosition
        let advanced = waitUntil(timeout: 15) {
            scrubber.normalizedSliderPosition > initial + 0.02
        }
        XCTAssertTrue(advanced, "scrubber never advanced — autoplay did not play")

        // Tap toggles sound.
        mute.tap()
        XCTAssertEqual(mute.value as? String, "unmuted", "tap must unmute")

        // Scrub to three positions; after each, playback keeps
        // presenting (the scrubber keeps moving). Landing precision
        // is not asserted — the clip is 3 s and LOOPING, so the
        // periodic observer legitimately rewrites the value within a
        // frame of the drag; frame presentation per seek position is
        // pinned by PlaybackCustodyTests.framesPresentAtStartAndAfterScrubs.
        for target in [0.8, 0.2, 0.5] {
            scrubber.adjust(toNormalizedSliderPosition: target)
            let position = scrubber.normalizedSliderPosition
            XCTAssertTrue(
                waitUntil(timeout: 15) {
                    scrubber.normalizedSliderPosition != position
                }, "playback stalled after scrubbing to \(target)")
        }
        app.buttons["pager-close"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))

        // --- Tampered item shows the DAMAGED state (distinct from
        // the unsupported one). The tamper seam flips a byte in the
        // newest playable video's first chunk and purges the cache.
        app.buttons["tamper-video-button"].tap()
        // The tamper seam is async (coordinator hop + cache purge):
        // give it a beat so the reopened stream reads the damaged
        // bytes cold instead of a still-resident clean chunk.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // The tamper seam targets the newest PLAYABLE video — the
        // same first value=='video' cell.
        grid.cells.matching(NSPredicate(format: "value == 'video'"))
            .element(boundBy: 0).tap()
        XCTAssertTrue(pagerClose.waitForExistence(timeout: 15))
        let damagedState = app.staticTexts["playback-state"]
        XCTAssertTrue(
            damagedState.waitForExistence(timeout: 20),
            "damaged state never appeared for tampered video")
        XCTAssertTrue(
            damagedState.label.contains("damaged or missing"),
            "expected damaged copy, got: \(damagedState.label)")
        app.buttons["pager-close"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 10))

        // --- Relaunch (same container) → locked → unlock → restore.
        app.terminate()
        app = launch(container: container)
        let unlockField = app.secureTextFields["unlock-password"]
        XCTAssertTrue(
            unlockField.waitForExistence(timeout: 15),
            "unlock screen missing after relaunch")
        unlockField.tap()
        unlockField.typeText(password)
        app.buttons["unlock-button"].tap()

        XCTAssertTrue(
            app.collectionViews["photo-grid"].waitForExistence(timeout: 60),
            "grid did not restore after unlock")

        // Per-item failure visible in the restored grid: the corrupt
        // original imported byte-exact but has no preview badge.
        let damagedCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == 'no preview' OR value == 'damaged'"))
            .firstMatch
        XCTAssertTrue(
            damagedCell.waitForExistence(timeout: 30),
            "no-preview/damaged badge not visible after restore")
    }

    func testWrongPasswordShowsAmbiguousCopy() throws {
        let container = "e2e-wrong-\(UUID().uuidString.prefix(8))"
        var app = launch(container: container, fresh: true)

        let passwordField = app.secureTextFields["setup-password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15))
        passwordField.tap()
        passwordField.typeText(password)
        let confirmField = app.secureTextFields["setup-confirm"]
        confirmField.tap()
        confirmField.typeText(password)
        app.buttons["setup-create"].tap()
        XCTAssertTrue(app.buttons["lock-button"].waitForExistence(timeout: 60))

        app.terminate()
        app = launch(container: container)
        let unlockField = app.secureTextFields["unlock-password"]
        XCTAssertTrue(unlockField.waitForExistence(timeout: 15))
        unlockField.tap()
        unlockField.typeText("not the password")
        app.buttons["unlock-button"].tap()

        let failure = app.staticTexts["unlock-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 30))
        XCTAssertTrue(
            failure.label.contains("indistinguishable"),
            "wrong-password copy must state tamper-ambiguity; got: \(failure.label)")
    }
}

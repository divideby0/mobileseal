import XCTest

/// CED-13 gate 2 — the scripted migration + delete e2e (review B14):
/// seed the committed PRE-MIGRATION (v0) vault → unlock (migration
/// runs transparently) → grid identical → import the fixture batch →
/// pager single delete → grid multi-select bulk delete → Recently
/// Deleted shows aggregates → restore one → purge one → relaunch →
/// states durable → playback of the restored item works.
final class MigrationDeleteUITests: XCTestCase {
    /// The committed v0 fixture's password (see
    /// `V0AppVaultFixtureGenerator`).
    private let migrationPassword = "e2e-migration-password"

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    private func launch(container: String, fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mobileseal-uitest",
            "-mobileseal-uitest-container", container,
            "-mobileseal-uitest-seed-v0", "1",
        ]
        if fresh {
            app.launchArguments.append(contentsOf: ["-mobileseal-uitest-reset", "1"])
        }
        app.launch()
        return app
    }

    private func unlock(_ app: XCUIApplication, password: String) {
        let unlockField = app.secureTextFields["unlock-password"]
        XCTAssertTrue(unlockField.waitForExistence(timeout: 15), "unlock screen missing")
        unlockField.tap()
        unlockField.typeText(password)
        app.buttons["unlock-button"].tap()
    }

    /// SwiftUI Menu identifiers do not reliably propagate to the
    /// rendered toolbar button — match identifier OR label.
    private func moreMenuButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(
            NSPredicate(format: "identifier == 'more-menu-button' OR label == 'More'")
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "More menu missing")
        return button
    }

    private func itemCount(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["item-count"]
        guard label.exists else { return nil }
        return Int(label.label)
    }

    func testMigrateDeleteRestorePurgeRelaunchPlayback() throws {
        let container = "e2e-mig-\(UUID().uuidString.prefix(8))"
        var app = launch(container: container, fresh: true)

        // --- The seeded v0 vault presents the UNLOCK screen (a
        // gallery exists), not setup. Unlock migrates transparently.
        unlock(app, password: migrationPassword)
        let grid = app.collectionViews["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 60), "grid never appeared post-migration")

        // --- Grid identical: the 3 fixture originals, with previews
        // decrypted through their migrated thumbnail links.
        XCTAssertTrue(
            waitUntil(timeout: 30) { itemCount(app) == 3 },
            "migrated grid should show exactly the 3 v0 originals; got \(String(describing: itemCount(app)))"
        )

        // --- Import the committed fixture batch (adds 113 items incl.
        // playable videos for the restore-playback leg).
        app.buttons["import-fixtures-button"].tap()
        let summary = app.otherElements["import-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 600), "import summary never appeared")
        app.buttons["summary-done"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 30) { itemCount(app) == 117 },
            "expected 3 migrated + 114 stored imports (113 ok + 1 byte-exact undecodable); got \(String(describing: itemCount(app)))"
        )

        // --- Pager single delete: the first playable VIDEO (so the
        // restored item exercises playback later).
        let videoCells = grid.cells.matching(NSPredicate(format: "value == 'video'"))
        XCTAssertTrue(videoCells.firstMatch.waitForExistence(timeout: 15))
        videoCells.element(boundBy: 0).tap()
        let pagerDelete = app.buttons["pager-delete"]
        XCTAssertTrue(pagerDelete.waitForExistence(timeout: 15), "pager delete missing")
        pagerDelete.tap()
        let confirmPagerRemove = app.alerts.buttons["Remove"]
        XCTAssertTrue(confirmPagerRemove.waitForExistence(timeout: 10))
        confirmPagerRemove.tap()
        // The pager advances (does not dismiss); close it.
        let pagerClose = app.buttons["pager-close"]
        XCTAssertTrue(pagerClose.waitForExistence(timeout: 10))
        pagerClose.tap()
        XCTAssertTrue(
            waitUntil(timeout: 30) { itemCount(app) == 116 },
            "pager delete did not hide the aggregate")

        // --- Grid multi-select bulk delete: two stills.
        moreMenuButton(app).tap()
        let selectItem = app.buttons["Select"]
        XCTAssertTrue(selectItem.waitForExistence(timeout: 10))
        selectItem.tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        app.buttons["select-delete-button"].tap()
        let confirmBulk = app.buttons["Remove 2 Items"]
        XCTAssertTrue(confirmBulk.waitForExistence(timeout: 10), "bulk confirm missing")
        confirmBulk.tap()
        XCTAssertTrue(
            waitUntil(timeout: 30) { itemCount(app) == 114 },
            "bulk delete did not hide 2 aggregates")

        // --- Recently Deleted shows the 3 aggregates.
        moreMenuButton(app).tap()
        let recentlyDeletedItem = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Recently Deleted'")
        ).firstMatch
        XCTAssertTrue(recentlyDeletedItem.waitForExistence(timeout: 10))
        recentlyDeletedItem.tap()
        let sheet = app.otherElements["recently-deleted"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let rows = app.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'deleted-row-'"))
        XCTAssertTrue(
            waitUntil(timeout: 15) { rows.count == 3 },
            "expected 3 aggregates in Recently Deleted; got \(rows.count)")

        // Rows sort newest-deleted first: [still, still, video].
        // Restore the VIDEO (last row); purge one still (first row).
        let restoreButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'restore-'"))
        let videoRestore = restoreButtons.element(boundBy: restoreButtons.count - 1)
        videoRestore.tap()
        XCTAssertTrue(
            waitUntil(timeout: 15) { rows.count == 2 }, "restore did not clear the row")

        let purgeButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'purge-'"))
        purgeButtons.element(boundBy: 0).tap()
        let confirmPurge = app.buttons["Remove Permanently"]
        XCTAssertTrue(confirmPurge.waitForExistence(timeout: 10))
        confirmPurge.tap()
        XCTAssertTrue(
            waitUntil(timeout: 15) { rows.count == 1 }, "purge did not remove the row")
        app.buttons["recently-deleted-done"].tap()

        // Restored video is back in the grid: 114 + 1 = 115.
        XCTAssertTrue(
            waitUntil(timeout: 30) { itemCount(app) == 115 },
            "restored aggregate did not rejoin the grid")

        // --- Relaunch (same container, no reset) → all states durable.
        app.terminate()
        app = launch(container: container)
        unlock(app, password: migrationPassword)
        XCTAssertTrue(
            app.collectionViews["photo-grid"].waitForExistence(timeout: 60),
            "grid did not restore after relaunch")
        XCTAssertTrue(
            waitUntil(timeout: 30) { itemCount(app) == 115 },
            "grid count not durable after relaunch; got \(String(describing: itemCount(app)))"
        )
        moreMenuButton(app).tap()
        let recentlyDeletedAfter = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Recently Deleted'")
        ).firstMatch
        XCTAssertTrue(recentlyDeletedAfter.waitForExistence(timeout: 10))
        XCTAssertTrue(
            recentlyDeletedAfter.label.contains("(1)"),
            "soft-delete ledger not durable; label: \(recentlyDeletedAfter.label)")
        recentlyDeletedAfter.tap()
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                app.cells.matching(
                    NSPredicate(format: "identifier BEGINSWITH 'deleted-row-'")
                ).count == 1
            }, "Recently Deleted not durable across relaunch")
        app.buttons["recently-deleted-done"].tap()

        // --- Playback of the RESTORED item works: open the first
        // playable video (the restored one is among them) and assert
        // autoplay advances the scrubber.
        let restoredVideo = app.collectionViews["photo-grid"].cells.matching(
            NSPredicate(format: "value == 'video'")
        ).firstMatch
        XCTAssertTrue(restoredVideo.waitForExistence(timeout: 15), "no video cell after restore")
        restoredVideo.tap()
        XCTAssertTrue(app.buttons["pager-close"].waitForExistence(timeout: 15))
        let scrubber = app.sliders["video-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 20), "restored video never played")
        let initial = scrubber.normalizedSliderPosition
        XCTAssertTrue(
            waitUntil(timeout: 15) { scrubber.normalizedSliderPosition > initial + 0.02 },
            "restored video's playback did not advance")
        app.buttons["pager-close"].tap()
    }
}

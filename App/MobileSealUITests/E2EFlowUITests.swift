import XCTest

/// Gate 2 — the scripted end-to-end on simulator: create gallery →
/// import the committed fixture batch (110 mixed HEIC/JPEG + 1 forced
/// failure, ≥100) through the real pipeline (fixture provider seam;
/// the system picker gets a manual device smoke test) → grid renders
/// from encrypted thumbnails → relaunch → unlock → grid restores →
/// per-item failure visible.
final class E2EFlowUITests: XCTestCase {
    private let password = "e2e vault password 42"

    override func setUpWithError() throws {
        continueAfterFailure = false
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

        // --- Import the committed fixture batch.
        let importFixtures = app.buttons["import-fixtures-button"]
        XCTAssertTrue(
            importFixtures.waitForExistence(timeout: 60),
            "gallery (unlocked) never appeared after create")
        importFixtures.tap()

        // 110 healthy + 1 corrupt (last): the batch takes a while on
        // the simulator; the summary sheet marks completion.
        let summary = app.otherElements["import-summary"]
        let summaryShown = summary.waitForExistence(timeout: 600)
        XCTAssertTrue(summaryShown, "import summary never appeared")

        // Failure visible in the summary (forced per-item failure):
        // 110 healthy imported, the corrupt last item failed.
        let line = app.staticTexts["summary-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        XCTAssertEqual(
            line.label, "imported=110 skipped=0 failed=1 interrupted=false",
            "batch summary mismatch")
        app.buttons["summary-done"].tap()

        // --- Grid renders from encrypted thumbnails.
        let grid = app.otherElements["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "grid never appeared")
        XCTAssertTrue(
            app.cells.count > 0 || grid.descendants(matching: .any).count > 0,
            "grid rendered no cells")

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
            app.otherElements["photo-grid"].waitForExistence(timeout: 60),
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

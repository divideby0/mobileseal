import XCTest

/// CED-14 gate 2 — the scripted multi-gallery e2e: existing-vault
/// relaunch lands in its gallery unchanged (single gallery keeps
/// today's flow — no list) → create a second gallery (distinct
/// password; per-gallery calibration record visible in Settings) →
/// import into it → label + cover set while unlocked → switch back
/// (full-store teardown; wrong target password stays on the target's
/// unlock screen, Back to the list) → correct unlock restores gallery
/// 1's own content → relaunch shows the LIST with the device-local
/// label visible pre-unlock. (Migration atomicity/crash-injection and
/// label custody are unit-gated: MultiGalleryStateTests +
/// GallerySwitchboardTests.)
final class MultiGalleryUITests: XCTestCase {
    private let passwordA = "first gallery pw 1"
    private let passwordB = "second gallery pw 2"

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
        ]
        if fresh {
            app.launchArguments.append(contentsOf: ["-mobileseal-uitest-reset", "1"])
        }
        app.launch()
        return app
    }

    private func itemCount(_ app: XCUIApplication) -> Int? {
        let label = app.staticTexts["item-count"]
        guard label.exists else { return nil }
        return Int(label.label)
    }

    private func unlock(_ app: XCUIApplication, password: String) {
        let unlockField = app.secureTextFields["unlock-password"]
        XCTAssertTrue(unlockField.waitForExistence(timeout: 15), "unlock screen missing")
        unlockField.tap()
        unlockField.typeText(password)
        app.buttons["unlock-button"].tap()
    }

    func testTwoGalleriesCreateSwitchLabelRelaunch() throws {
        let container = "e2e-multi-\(UUID().uuidString.prefix(8))"
        var app = launch(container: container, fresh: true)

        // --- Create gallery 1 (the pre-CED-14 single-gallery flow).
        let passwordField = app.secureTextFields["setup-password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 15), "setup never appeared")
        passwordField.tap()
        passwordField.typeText(passwordA)
        let confirmField = app.secureTextFields["setup-confirm"]
        confirmField.tap()
        confirmField.typeText(passwordA)
        app.buttons["setup-create"].tap()

        // Seed twice → 24 items (real commits through the Gallery
        // actor; batch fidelity is E2EFlowUITests' gate).
        XCTAssertTrue(app.tapMoreMenuItem(label: "Seed 12", timeout: 60))
        XCTAssertTrue(waitUntil(timeout: 60) { self.itemCount(app) == 12 })
        XCTAssertTrue(app.tapMoreMenuItem(label: "Seed 12"))
        XCTAssertTrue(waitUntil(timeout: 60) { self.itemCount(app) == 24 })

        // --- Existing-vault relaunch lands in ITS gallery unchanged:
        // one gallery → straight to the unlock screen (no list), and
        // the content is intact after unlock.
        app.terminate()
        app = launch(container: container)
        XCTAssertFalse(
            app.buttons["gallery-tile-0"].exists,
            "single-gallery relaunch must not land on the list")
        unlock(app, password: passwordA)
        XCTAssertTrue(
            app.collectionViews["photo-grid"].waitForExistence(timeout: 60),
            "gallery 1 did not restore after relaunch")
        XCTAssertTrue(waitUntil(timeout: 30) { self.itemCount(app) == 24 })

        // --- Create gallery 2 from Settings (the one-gallery "New
        // Gallery" affordance), with a DISTINCT password and a
        // device-local name typed at creation.
        XCTAssertTrue(app.tapMoreMenuItem(label: "Settings"))
        let newGallery = app.buttons["settings-new-gallery"]
        XCTAssertTrue(newGallery.waitForExistence(timeout: 10))
        newGallery.tap()
        let nameField = app.textFields["create-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Beta Vault")
        let createPassword = app.secureTextFields["create-password"]
        createPassword.tap()
        createPassword.typeText(passwordB)
        let createConfirm = app.secureTextFields["create-confirm"]
        createConfirm.tap()
        createConfirm.typeText(passwordB)
        app.buttons["create-submit"].tap()

        // Creation adopts gallery 2 unlocked (calibration ran inside).
        // An empty gallery shows the empty-import state, not the grid.
        let grid = app.collectionViews["photo-grid"]
        XCTAssertTrue(
            waitUntil(timeout: 60) {
                app.buttons["empty-import-button"].exists && self.itemCount(app) == 0
            },
            "gallery 2 did not open empty after creation")

        // Per-gallery calibration record visible in gallery 2's
        // Settings (WS A.1: the calibrator ran for THIS gallery).
        XCTAssertTrue(app.tapMoreMenuItem(label: "Settings"))
        XCTAssertTrue(
            app.otherElements["calibration-record"].waitForExistence(timeout: 10)
                || app.staticTexts["Chosen parameters"].waitForExistence(timeout: 5),
            "gallery 2 has no calibration record")
        app.buttons["settings-done"].tap()

        // --- Import into gallery 2.
        XCTAssertTrue(app.tapMoreMenuItem(label: "Seed 12"))
        XCTAssertTrue(waitUntil(timeout: 60) { self.itemCount(app) == 12 })

        // --- Cover set while unlocked (explicit per-device opt-in).
        XCTAssertTrue(app.tapMoreMenuItem(label: "Select"))
        let firstCell = grid.cells.firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 10))
        firstCell.tap()
        let setCover = app.buttons["select-set-cover-button"]
        XCTAssertTrue(setCover.waitForExistence(timeout: 10))
        setCover.tap()

        // --- Switch back: full teardown → the LIST (holds no DEK).
        XCTAssertTrue(app.tapMoreMenuItem(label: "Switch Gallery"))
        let tile0 = app.buttons["gallery-tile-0"]
        XCTAssertTrue(tile0.waitForExistence(timeout: 30), "gallery list never appeared")
        // The device-local label is visible on the locked list.
        XCTAssertTrue(
            app.staticTexts["Beta Vault"].waitForExistence(timeout: 10),
            "device-local name missing from the locked list")
        // The chosen cover RENDERS on the locked list (tile 1 = the
        // newer Beta gallery): its machine-readable state flips from
        // "generic" to "cover".
        let tile1 = app.buttons["gallery-tile-1"]
        XCTAssertTrue(tile1.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil(timeout: 15) { tile1.value as? String == "cover" },
            "cover never rendered on the locked list; value=\(String(describing: tile1.value))"
        )

        // Gallery 1 (older created-date → tile 0): WRONG password
        // leaves the app on ITS unlock screen, locked (plan review
        // Q15) — Back returns to the list.
        tile0.tap()
        unlock(app, password: "definitely not it")
        let failure = app.staticTexts["unlock-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.secureTextFields["unlock-password"].exists,
            "must stay on the target's unlock screen after a wrong password")
        let back = app.buttons["back-to-list-button"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(tile0.waitForExistence(timeout: 15), "Back did not return to the list")

        // Correct password: gallery 1 restores with its OWN 24 items.
        tile0.tap()
        unlock(app, password: passwordA)
        XCTAssertTrue(grid.waitForExistence(timeout: 60), "gallery 1 did not unlock")
        XCTAssertTrue(
            waitUntil(timeout: 30) { self.itemCount(app) == 24 },
            "gallery 1 content changed across the switch; got \(String(describing: itemCount(app)))"
        )

        // --- Relaunch with two galleries → the LIST is the root, the
        // label still visible pre-unlock, no unlock field shown.
        app.terminate()
        app = launch(container: container)
        XCTAssertTrue(
            app.buttons["gallery-tile-0"].waitForExistence(timeout: 30),
            "two-gallery relaunch must land on the list")
        XCTAssertTrue(app.buttons["gallery-tile-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Beta Vault"].waitForExistence(timeout: 10),
            "label lost across relaunch")
        XCTAssertFalse(app.secureTextFields["unlock-password"].exists)
    }
}

import XCTest

/// Walks the main screens on the `-uiTestFixtures` build (seeded route, stub backend): accepting a
/// suggestion through to the uploaded summary. With `TEST_RUNNER_SCREENSHOTS_DIR=…` on the xcodebuild
/// command line it also saves a screenshot of each screen.
final class ScreenshotTourTests: AppUITestCase {

    func testTourOfTheRideLoop() {
        app.launch()

        let startRide = app.buttons["Start Ride"]
        XCTAssertTrue(startRide.waitForExistence(timeout: 10), "the seeded route should show on Home")
        dismissSystemAlerts()
        snapshot("01-home")

        app.buttons["Demo Mode"].tap()
        XCTAssertTrue(app.buttons["Start Demo Ride"].waitForExistence(timeout: 5))
        snapshot("02-demo-mode")

        app.buttons["Start Demo Ride"].tap()
        let finish = app.buttons["Hold to finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "the live ride cover should appear")
        snapshot("03-live-ride", settle: 4)  // let the replay move the rider and the map settle

        // The stub backend suggests the seeded café, which is ahead of the rider.
        let card = app.waitForSuggestionCard()
        XCTAssertTrue(card.exists, "the suggestion card should appear")
        snapshot("04-suggestion-card")

        card.tap()
        XCTAssertTrue(app.buttons["Directions"].waitForExistence(timeout: 5), "the stop sheet should open")
        snapshot("05-stop-sheet")
        app.buttons["Accept"].tap()
        app.swipeDown(velocity: .fast)  // close the sheet; the card switches to "Heading to"
        snapshot("06-heading-to", settle: 1)

        finish.press(forDuration: 2.0)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the summary should replace the dashboard")
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10), "the stub backend accepts the upload")
        snapshot("07-ride-summary")

        done.tap()
        XCTAssertTrue(startRide.waitForExistence(timeout: 5), "Done returns Home")
    }

    func testReadinessSheet() throws {
        try skipUnlessSavingScreenshots()
        app.launchArguments += ["-uiTestMissingPermissions"]
        app.launch()

        let startRide = app.buttons["Start Ride"]
        XCTAssertTrue(startRide.waitForExistence(timeout: 10))
        dismissSystemAlerts()
        startRide.tap()

        XCTAssertTrue(app.buttons["Start without suggestions"].waitForExistence(timeout: 5), "the readiness sheet opens")
        XCTAssertTrue(app.buttons["Open Settings"].exists, "denied notifications point to Settings")
        snapshot("08-readiness-check")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(startRide.waitForExistence(timeout: 5))

        app.buttons["View map"].tap()
        XCTAssertTrue(app.staticTexts["2 stops found"].waitForExistence(timeout: 5), "the corridor map loads the stored route")
        snapshot("09-corridor-map", settle: 2)  // let map tiles load
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(startRide.waitForExistence(timeout: 5), "back returns Home")
    }
}

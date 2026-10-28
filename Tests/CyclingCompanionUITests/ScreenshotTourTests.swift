import XCTest

/// Walks the main screens on the `-uiTestFixtures` build (seeded route, stub backend) and saves a
/// screenshot of each. Screenshots are attached to the test result and, when the
/// `SCREENSHOTS_DIR` environment variable is set (pass `TEST_RUNNER_SCREENSHOTS_DIR=…` to
/// xcodebuild), also written there as PNGs. Extended as milestone 7's screens land.
final class ScreenshotTourTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFixtures"]
        // A system permission alert must never sit on top of a screenshot.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    func testTourOfTheRideLoop() {
        app.launch()

        let startRide = app.buttons["Start Ride"]
        XCTAssertTrue(startRide.waitForExistence(timeout: 10), "the seeded route should show on Home")
        dismissSystemAlerts()
        snapshot("01-home")

        app.buttons["Demo Mode"].tap()
        XCTAssertTrue(app.buttons["Start Demo Ride"].waitForExistence(timeout: 5))
        snapshot("02-demo-mode")

        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 1.0)  // 20x, past the 10-minute quiet window sooner
        app.buttons["Start Demo Ride"].tap()
        let finish = app.buttons["Hold to finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "the live ride cover should appear")
        sleep(4)  // let the replay move the rider and the map settle
        snapshot("03-live-ride")

        // Past the advisor's 10-minute quiet period (ride time) the stub backend suggests the seeded
        // café, which is still ahead of the rider.
        let card = app.waitForSuggestionCard()
        XCTAssertTrue(card.exists, "the suggestion card should appear")
        snapshot("04-suggestion-card")

        card.tap()
        XCTAssertTrue(app.buttons["Directions"].waitForExistence(timeout: 5), "the stop sheet should open")
        snapshot("05-stop-sheet")
        app.buttons["Accept"].tap()
        app.swipeDown(velocity: .fast)  // close the sheet; the card switches to "Heading to"
        sleep(1)
        snapshot("06-heading-to")

        finish.press(forDuration: 2.0)
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the summary should replace the dashboard")
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10), "the stub backend accepts the upload")
        snapshot("07-ride-summary")

        done.tap()
        XCTAssertTrue(startRide.waitForExistence(timeout: 5), "Done returns Home")
    }

    func testReadinessSheet() {
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
        sleep(2)  // let map tiles load
        snapshot("09-corridor-map")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(startRide.waitForExistence(timeout: 5), "back returns Home")
    }

    /// A location prompt left over from the unit tests in the same run (`CoreLocationSource.init`
    /// requests authorization until task-6.1) must not cover a screenshot.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 where springboard.alerts.firstMatch.waitForExistence(timeout: 1) {
            let alert = springboard.alerts.firstMatch
            let button = ["Allow While Using App", "Allow", "OK"].map { alert.buttons[$0] }.first { $0.exists }
            (button ?? alert.buttons.firstMatch).tap()
        }
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let directory = ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}

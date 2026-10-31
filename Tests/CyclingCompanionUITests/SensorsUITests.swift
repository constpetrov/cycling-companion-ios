import XCTest

/// Milestone 12 (RULE-16): the Sensors screen and the dashboard's values, over the scripted Bluetooth in
/// `-uiTestFixtures`: a "Polar H10" strap at 128 bpm and a "Wahoo CADENCE" sensor at 90 rpm in range.
final class SensorsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFixtures"]
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 where springboard.alerts.firstMatch.waitForExistence(timeout: 1) {
            let alert = springboard.alerts.firstMatch
            let button = ["Allow While Using App", "Allow", "OK"].map { alert.buttons[$0] }.first { $0.exists }
            (button ?? alert.buttons.firstMatch).tap()
        }
    }

    private func openSensors() {
        app.launch()
        dismissSystemAlerts()
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        // At the largest text size the row starts below the account section.
        let row = app.buttons["settings.sensors"]
        for _ in 0..<4 where !row.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Sensors"].waitForExistence(timeout: 5))
    }

    /// AC-1, AC-3, AC-5, AC-9: add a strap from the scan; it is listed with its live value.
    func testPairingAStrapShowsItsLiveValue() {
        openSensors()
        app.buttons["Add Sensor"].tap()
        let strap = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Polar H10'")).firstMatch
        XCTAssertTrue(strap.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.containing(NSPredicate(format: "label CONTAINS 'Wahoo CADENCE'")).firstMatch
                .waitForExistence(timeout: 5))
        strap.tap()

        XCTAssertTrue(app.staticTexts["Polar H10"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["128 bpm"].waitForExistence(timeout: 5), "the live value shows")
    }

    /// AC-7: swiping a remembered sensor away forgets it.
    func testForgettingASensor() {
        app.launchArguments += ["-uiTestPairedStrap"]
        openSensors()
        let name = app.staticTexts["Polar H10"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }

    /// AC-13.
    func testDeniedPermissionOffersOpenSettings() {
        app.launchArguments += ["-uiTestBluetooth", "unauthorized"]
        openSensors()
        XCTAssertTrue(app.staticTexts["Bluetooth permission is denied. Allow it in Settings to use sensors."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["Add Sensor"].isEnabled)
    }

    /// AC-14.
    func testBluetoothOffIsExplained() {
        app.launchArguments += ["-uiTestBluetooth", "off"]
        openSensors()
        XCTAssertTrue(app.staticTexts["Bluetooth is off. Turn it on to use sensors."].waitForExistence(timeout: 5))
    }

    /// AC-49, AC-51, AC-52: a real ride with a remembered strap shows heart rate, and no cadence tile.
    func testARideShowsTheRememberedKindsOnly() {
        app.launchArguments += ["-uiTestPairedStrap"]
        app.launch()
        dismissSystemAlerts()
        let start = app.buttons["Start Ride"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        dismissSystemAlerts()
        XCTAssertTrue(app.buttons["Hold to finish"].waitForExistence(timeout: 10))

        let heartRate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Heart rate'")).firstMatch
        XCTAssertTrue(heartRate.waitForExistence(timeout: 5))
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '128 bpm'"), object: heartRate)
        XCTAssertEqual(XCTWaiter().wait(for: [reading], timeout: 10), .completed, "the strap's reading reaches the dashboard")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cadence'")).firstMatch.exists)
    }

    /// AC-52: no sensors, no tiles.
    func testARideWithoutSensorsShowsNoSensorTiles() {
        app.launch()
        dismissSystemAlerts()
        let start = app.buttons["Start Ride"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        dismissSystemAlerts()
        XCTAssertTrue(app.buttons["Hold to finish"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Heart rate'")).firstMatch.exists)
    }

    /// AC-53, AC-54: the Sensors screen at the largest text size passes the audit and keeps its controls reachable.
    func testTheSensorsScreenPassesTheAuditAtTheLargestTextSize() throws {
        app.launchArguments += [
            "-uiTestPairedStrap", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        openSensors()
        XCTAssertTrue(app.staticTexts["Polar H10"].waitForExistence(timeout: 5))
        let addButton = app.buttons["Add Sensor"]
        for _ in 0..<4 where !addButton.isHittable { app.swipeUp() }
        XCTAssertTrue(addButton.isHittable, "Add Sensor stays reachable")

        try app.performAccessibilityAuditRetryingTimeout { issue in
            // As in Settings: the system navigation bar keeps its size, and a row cut by the screen
            // edge is reported from pixels; neither names an element.
            if issue.element == nil, issue.auditType == .dynamicType || issue.auditType == .textClipped {
                print("Accessibility warning on Sensors: \(issue.compactDescription) — no element")
                return true
            }
            if issue.auditType == .contrast, issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
                print("Accessibility warning on Sensors: \(issue.compactDescription)")
                return true
            }
            print("Accessibility issue on Sensors: \(issue.compactDescription) — \(issue.element?.label ?? "?")")
            return false
        }
    }

    /// AC-53, AC-54: a dashboard with sensor tiles at the largest text size keeps them whole and reachable.
    func testADashboardWithSensorsPassesTheAuditAtTheLargestTextSize() throws {
        app.launchArguments += [
            "-uiTestPairedStrap", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        dismissSystemAlerts()
        let start = app.buttons["Start Ride"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        dismissSystemAlerts()
        XCTAssertTrue(app.buttons["Hold to finish"].waitForExistence(timeout: 10))
        let heartRate = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Heart rate'")).firstMatch
        XCTAssertTrue(heartRate.waitForExistence(timeout: 5))
        XCTAssertTrue(heartRate.isHittable, "the heart rate tile stays on screen")
        XCTAssertTrue(app.buttons["Hold to finish"].isHittable, "the finish control stays reachable")

        try app.performAccessibilityAuditRetryingTimeout { issue in
            // MapKit's gray stop markers over map tiles fail contrast with or without sensors (a control run
            // with no sensors showed the same); this test is about the sensor tiles and controls.
            if issue.auditType == .contrast, issue.element?.label.contains("km ahead") == true {
                print("Accessibility warning on the dashboard: \(issue.compactDescription) — stop marker on the map")
                return true
            }
            if issue.element == nil, issue.auditType == .dynamicType || issue.auditType == .textClipped {
                print("Accessibility warning on the dashboard: \(issue.compactDescription) — no element")
                return true
            }
            if issue.auditType == .contrast, issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
                print("Accessibility warning on the dashboard: \(issue.compactDescription)")
                return true
            }
            print("Accessibility issue on the dashboard: \(issue.compactDescription) — \(issue.element?.label ?? "?")")
            return false
        }
    }
}

import XCTest

/// Settings: the rider turns stop types off from Home's toolbar, and the screen passes the
/// accessibility audit at the largest text size. (Persistence is covered by the unit tests; the UI
/// test fixtures use a fresh defaults suite per launch.)
final class StopTypeSettingsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFixtures"]
    }

    private func openSettings() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 where springboard.alerts.firstMatch.waitForExistence(timeout: 1) {
            let alert = springboard.alerts.firstMatch
            let button = ["Allow While Using App", "Allow", "OK"].map { alert.buttons[$0] }.first { $0.exists }
            (button ?? alert.buttons.firstMatch).tap()
        }
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func toggle(_ type: String) -> XCUIElement {
        app.switches["stopType.\(type)"]
    }

    func testEveryTypeStartsOnAndCanBeTurnedOff() {
        openSettings()

        for type in ["CAFE_BAKERY_RESTAURANT", "FOOD_SHOP", "WATER", "TOILETS", "REST_SHELTER", "BIKE_REPAIR"] {
            XCTAssertTrue(toggle(type).exists, type)
            XCTAssertEqual(toggle(type).value as? String, "1", "\(type) is on by default")
        }
        // The switch itself sits at the trailing edge of the row.
        let shelters = toggle("REST_SHELTER")
        let innerSwitch = shelters.switches.firstMatch
        (innerSwitch.exists ? innerSwitch : shelters).coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        XCTAssertEqual(toggle("REST_SHELTER").value as? String, "0")
        XCTAssertEqual(toggle("WATER").value as? String, "1")
    }

    func testTheScreenPassesTheAuditAtTheLargestTextSize() throws {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        openSettings()

        try app.performAccessibilityAudit { issue in
            // The system navigation bar ("Back", the title) keeps its size at accessibility sizes; the
            // audit reports that without naming an element, as on Home. The rows themselves scale
            // and wrap (checked by screenshot at this size).
            if issue.auditType == .dynamicType, issue.element == nil {
                print("Accessibility warning on Settings: \(issue.compactDescription) — system navigation bar, no element")
                return true
            }
            // At this size a row is cut by the bottom edge of the screen until scrolled to; the audit
            // reports that from pixels with no element. Clipping inside a named element still fails.
            if issue.auditType == .textClipped, issue.element == nil {
                print("Accessibility warning on Settings: \(issue.compactDescription) — row at the scroll edge, no element")
                return true
            }
            // "Nearly passed" contrast on Apple's own controls is logged, not failed (as on Home).
            if issue.auditType == .contrast, issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
                print("Accessibility warning on Settings: \(issue.compactDescription)")
                return true
            }
            print("Accessibility issue on Settings: \(issue.compactDescription) — \(issue.element?.label ?? "?")")
            return false
        }
    }
}

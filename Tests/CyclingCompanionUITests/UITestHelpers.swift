import XCTest

// Shared helpers for the UI tests.

/// Launches on the `-uiTestFixtures` build (seeded route, stub backend, no animations). A system
/// alert that shows up after `dismissSystemAlerts()` is answered when the next tap runs into it.
class AppUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFixtures"]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    /// Answers a permission alert left on screen at launch. Returns at the first look that finds none, so
    /// it costs half a second when there are no alerts.
    func dismissSystemAlerts() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        for _ in 0..<3 {
            guard alert.waitForExistence(timeout: 0.5) else { return }
            let button = ["Allow While Using App", "Allow", "OK"].map { alert.buttons[$0] }.first { $0.exists }
            (button ?? alert.buttons.firstMatch).tap()
        }
    }

    /// Set with `TEST_RUNNER_SCREENSHOTS_DIR=…` on the xcodebuild command line.
    private var screenshotsDirectory: String? {
        ProcessInfo.processInfo.environment["SCREENSHOTS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// For tests that only produce screenshots for the docs: they don't run on a normal test run.
    func skipUnlessSavingScreenshots() throws {
        try XCTSkipUnless(screenshotsDirectory != nil, "only runs with TEST_RUNNER_SCREENSHOTS_DIR set")
    }

    /// Saves a PNG and attaches it to the result, only when asked for screenshots. Waits `settle` seconds first.
    func snapshot(_ name: String, settle: UInt32 = 0) {
        guard let screenshotsDirectory else { return }
        sleep(settle)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: screenshotsDirectory).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: url)
    }
}

extension XCUIApplication {
    /// `performAccessibilityAudit`, retried once when the audit itself times out ("Audit failed to complete in time",
    /// code -56), which happens on slow CI runners and says nothing about the app. Findings are never retried.
    func performAccessibilityAuditRetryingTimeout(_ issueHandler: @escaping (XCUIAccessibilityAuditIssue) throws -> Bool)
        throws
    {
        do {
            try performAccessibilityAudit(issueHandler)
        } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
            print("Accessibility audit timed out; retrying once")
            try performAccessibilityAudit(issueHandler)
        }
    }
}

extension XCUIApplication {
    /// The seeded café's suggestion card on the live dashboard, forcing an advisor check until it shows. In the
    /// fixtures the post-start quiet period doesn't apply, so the first check that has a location fix shows it.
    func waitForSuggestionCard(timeout: TimeInterval = 30) -> XCUIElement {
        let card = buttons.matching(NSPredicate(format: "label CONTAINS %@", "Café am Kanal")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !card.exists, Date() < deadline {
            buttons["dashboard.forceCheck"].tap()
            _ = card.waitForExistence(timeout: 2)
        }
        return card
    }
}

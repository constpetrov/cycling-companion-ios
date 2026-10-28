import XCTest

// Shared helpers for the UI tests.

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
    /// The seeded café's suggestion card on the live dashboard, forcing an advisor check every 5 s until it shows.
    /// The card can only appear once the demo ride is past the advisor's 10-minute quiet period (ride time), about
    /// 30 s of replay at 20x on a fast machine; on a slow CI runner the replay runs well behind that, so this waits on
    /// time (3 minutes, about the whole route) rather than a fixed number of checks.
    func waitForSuggestionCard(timeout: TimeInterval = 180) -> XCUIElement {
        let card = buttons.matching(NSPredicate(format: "label CONTAINS %@", "Café am Kanal")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !card.exists, Date() < deadline {
            buttons["dashboard.forceCheck"].tap()
            _ = card.waitForExistence(timeout: 5)
        }
        return card
    }
}

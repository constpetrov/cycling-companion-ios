import XCTest

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

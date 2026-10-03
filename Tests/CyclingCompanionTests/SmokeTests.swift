import XCTest

// RULE-27 in spec/rules.md pins XCTest for iOS unit tests. A trivial smoke test confirming the
// scaffold compiles and the test target runs; real coverage lands with task-2.1 onward.
final class SmokeTests: XCTestCase {
    func testScaffoldCompiles() {
        XCTAssertEqual(1 + 1, 2)
    }
}

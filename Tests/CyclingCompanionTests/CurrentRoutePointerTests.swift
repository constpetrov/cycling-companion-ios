import XCTest

@testable import CyclingCompanion

/// task-2.2 validation (RULE-8 in spec/rules.md): get/set/clear.
final class CurrentRoutePointerTests: XCTestCase {

    private func freshPointer() -> CurrentRoutePointer {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return CurrentRoutePointer(defaults: defaults)
    }

    func testRouteIdIsNilByDefault() {
        let pointer = freshPointer()

        XCTAssertNil(pointer.routeId)
    }

    func testSettingRouteIdPersistsIt() {
        var pointer = freshPointer()

        pointer.routeId = "route-1"

        XCTAssertEqual(pointer.routeId, "route-1")
    }

    func testClearRemovesThePointer() {
        var pointer = freshPointer()
        pointer.routeId = "route-1"

        pointer.clear()

        XCTAssertNil(pointer.routeId)
    }
}

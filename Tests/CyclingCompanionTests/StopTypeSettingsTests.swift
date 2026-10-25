import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Settings: the rider can turn stop types off; off types aren't drawn or suggested.
@MainActor
final class StopTypeSettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "stop-types-\(UUID().uuidString)")
    }

    private func stop(_ id: Int64, _ type: String) -> PersistedPoiInput {
        PersistedPoiInput(osmId: id, type: type, name: nil, latitude: 52, longitude: 13, kmMarkMeters: 0, detourMeters: 0,
                          openingHours: nil)
    }

    func testEveryTypeIsOnByDefault() {
        let settings = StopTypeSettings(defaults: defaults)

        XCTAssertTrue(StopType.allCases.allSatisfy(settings.isEnabled))
        XCTAssertFalse(settings.allDisabled)
    }

    func testTheTypesMatchTheBackendClassifier() {
        XCTAssertEqual(
            Set(StopType.allCases.map(\.rawValue)),
            ["CAFE_BAKERY_RESTAURANT", "FOOD_SHOP", "WATER", "TOILETS", "REST_SHELTER", "BIKE_REPAIR"])
    }

    func testATypeTurnedOffIsRememberedAcrossLaunches() {
        StopTypeSettings(defaults: defaults).setEnabled(false, for: .restShelter)

        let relaunched = StopTypeSettings(defaults: defaults)

        XCTAssertFalse(relaunched.isEnabled(.restShelter))
        XCTAssertTrue(relaunched.isEnabled(.water))
    }

    func testTheRideFilterSeesAChangeStraightAway() {
        let settings = StopTypeSettings(defaults: defaults)
        let stops = [stop(1, "REST_SHELTER"), stop(2, "WATER"), stop(3, "TOILETS")]

        settings.setEnabled(false, for: .restShelter)
        XCTAssertEqual(settings.filter.apply(stops).map(\.osmId), [2, 3])

        settings.setEnabled(true, for: .restShelter)
        XCTAssertEqual(settings.filter.apply(stops).map(\.osmId), [1, 2, 3])
    }

    func testATypeTheAppDoesNotKnowStaysOn() {
        let settings = StopTypeSettings(defaults: defaults)
        StopType.allCases.forEach { settings.setEnabled(false, for: $0) }

        XCTAssertTrue(settings.allDisabled)
        XCTAssertEqual(settings.filter.apply([stop(1, "WATER"), stop(2, "ICE_CREAM")]).map(\.osmId), [2])
    }
}

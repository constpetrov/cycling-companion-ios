import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-7.1 (RULE-28): AC-132 — map stops are reachable by VoiceOver as a list with name and distance.
final class AccessibilityLabelTests: XCTestCase {

    private func stop(_ id: Int64, name: String?, kmMark: Double) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: id, type: "CAFE_BAKERY_RESTAURANT", name: name, latitude: 52, longitude: 13, kmMarkMeters: kmMark,
            detourMeters: 50, openingHours: nil)
    }

    @MainActor
    func testDashboardStopsReadAsNameAndDistanceAhead() {
        let tracker = RideTracker(
            rideId: "r", routeId: "route-1", startTime: Date(), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: NoSensorSource(), clock: ReplayClock(),
            rideStore: RideStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        let viewModel = LiveRideViewModel(tracker: tracker, locale: Locale(identifier: "de_DE"))

        let named = viewModel.stopAccessibilityLabel(stop(1, name: "Café am Kanal", kmMark: 2_300))
        let unnamed = viewModel.stopAccessibilityLabel(stop(2, name: nil, kmMark: 600))

        XCTAssertTrue(named.hasPrefix("Café am Kanal, "))
        XCTAssertTrue(named.hasSuffix(" ahead"))
        XCTAssertTrue(named.contains("km"))
        XCTAssertTrue(unnamed.hasPrefix("Cafe bakery restaurant, "), "unnamed stops get a readable type, not CAFE_BAKERY_RESTAURANT")
    }

    func testCorridorMapStopsAreListedInRouteOrder() {
        let view = CorridorMapView(points: [], pois: [stop(2, name: "Later", kmMark: 5_000), stop(1, name: "Sooner", kmMark: 1_000)])

        let labels = view.stopAccessibilityLabels

        XCTAssertEqual(labels.count, 2)
        XCTAssertTrue(labels[0].hasPrefix("Sooner, "))
        XCTAssertTrue(labels[1].hasPrefix("Later, "))
    }
}

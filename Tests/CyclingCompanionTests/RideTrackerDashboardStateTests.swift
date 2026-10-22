import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.2 (RULE-12 in milestone 7's rules.md): the state the dashboard's off-route and no-GPS
/// badges are derived from (AC-26, AC-27, AC-28, AC-30).
final class RideTrackerDashboardStateTests: XCTestCase {

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
        ]
    }

    /// A fix halfway along the route, offset due north by `offRouteMeters` using the same
    /// equirectangular approximation `GeoMath.closestPointOnRoute` uses.
    private func fix(offRouteMeters: Double, time: TimeInterval) -> LocationFix {
        let latitude = 52.0 + (offRouteMeters / GeoMath.earthRadiusMeters) * 180 / .pi
        return LocationFix(
            latitude: latitude, longitude: 13.005, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: time))
    }

    @MainActor
    private func tracker(fixes: [LocationFix], clock: Clock = ReplayClock()) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: route(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: clock,
            rideStore: RideStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    }

    @MainActor
    func testToleranceIsFiftyMetres() {
        XCTAssertEqual(RideTracker.corridorToleranceMeters, 50)
    }

    @MainActor
    func testPublishesTheLatestFixesDistanceFromTheRoute() async {
        for offset in [49.0, 50.0, 51.0] {
            let tracker = tracker(fixes: [fix(offRouteMeters: offset, time: 10)])

            await tracker.start()

            let published = try? XCTUnwrap(tracker.latestOffRouteMeters)
            XCTAssertEqual(published ?? -1, offset, accuracy: 0.01, "offset \(offset) m")
        }
    }

    @MainActor
    func testOffRouteDistanceFollowsTheMostRecentFix() async {
        let tracker = tracker(fixes: [fix(offRouteMeters: 120, time: 10), fix(offRouteMeters: 5, time: 20)])

        await tracker.start()

        XCTAssertEqual(tracker.latestOffRouteMeters ?? -1, 5, accuracy: 0.01)
    }

    @MainActor
    func testNoFixYetMeansNoOffRouteDistanceAndNoLastFixTime() {
        let tracker = tracker(fixes: [])

        XCTAssertNil(tracker.latestOffRouteMeters)
        XCTAssertNil(tracker.lastFixAt)
    }

    @MainActor
    func testLastFixTimeComesFromTheInjectedClock() async {
        let clockStart = Date(timeIntervalSince1970: 5_000)
        let tracker = tracker(fixes: [fix(offRouteMeters: 0, time: 10)], clock: ReplayClock(start: clockStart))

        await tracker.start()

        XCTAssertEqual(tracker.lastFixAt, clockStart, "taken from the clock, not the fix's own timestamp (10)")
    }
}

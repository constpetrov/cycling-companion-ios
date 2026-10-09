import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.2 validation: the 50 m corridor gate (AC-2/AC-3/AC-4/AC-6), matching the same
/// within/at/beyond/resume pattern as `GeoMathClosestPointTests`, but driven through
/// `RideTracker` itself so the gating logic (not just the underlying geometry) is covered.
final class RideTrackerMapMatchingTests: XCTestCase {

    private let segmentEnd = 1_000.0

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: segmentEnd),
        ]
    }

    /// A fix at a given fraction along the route's longitude span, offset due north by
    /// `offRouteMeters` — the same equirectangular approximation `GeoMath.closestPointOnRoute`
    /// itself uses, so the off-route distance the test asserts against matches what the
    /// implementation actually computes.
    private func fix(fractionAlongRoute: Double, offRouteMeters: Double, time: TimeInterval) -> LocationFix {
        let longitude = 13.0 + fractionAlongRoute * 0.01
        let dLatRadians = offRouteMeters / GeoMath.earthRadiusMeters
        let latitude = 52.0 + dLatRadians * 180 / .pi
        return LocationFix(
            latitude: latitude, longitude: longitude, speedMetersPerSecond: 5,
            timestamp: Date(timeIntervalSince1970: time))
    }

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func tracker(fixes: [LocationFix]) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: route(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: freshRideStore())
    }

    @MainActor
    func testFixWithinCorridorAdvancesDistanceAlongRoute() async {
        let tracker = tracker(fixes: [fix(fractionAlongRoute: 0.5, offRouteMeters: 10, time: 0)])

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, segmentEnd * 0.5, accuracy: 1.0)
        XCTAssertEqual(tracker.track.count, 1)
    }

    @MainActor
    func testFixExactlyAtCorridorBoundaryAdvancesDistanceAlongRoute() async {
        let tracker = tracker(fixes: [fix(fractionAlongRoute: 0.5, offRouteMeters: 50, time: 0)])

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, segmentEnd * 0.5, accuracy: 1.0)
        XCTAssertEqual(tracker.track.count, 1)
    }

    @MainActor
    func testFixBeyondCorridorDoesNotAdvanceButIsRecorded() async {
        let fixes = [
            fix(fractionAlongRoute: 0.3, offRouteMeters: 10, time: 0),
            fix(fractionAlongRoute: 0.8, offRouteMeters: 51, time: 1),
        ]
        let tracker = tracker(fixes: fixes)

        await tracker.start()

        XCTAssertEqual(
            tracker.distanceAlongRouteMeters, segmentEnd * 0.3, accuracy: 1.0,
            "an off-route fix must not move distance-along-route")
        XCTAssertEqual(tracker.track.count, 2, "the off-route fix must still be recorded in the raw track")
    }

    @MainActor
    func testFixReturningToCorridorResumesAdvancing() async {
        let fixes = [
            fix(fractionAlongRoute: 0.2, offRouteMeters: 10, time: 0),
            fix(fractionAlongRoute: 0.6, offRouteMeters: 60, time: 1),
            fix(fractionAlongRoute: 0.9, offRouteMeters: 5, time: 2),
        ]
        let tracker = tracker(fixes: fixes)

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, segmentEnd * 0.9, accuracy: 1.0)
        XCTAssertEqual(tracker.track.count, 3)
    }
}

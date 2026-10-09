import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.3 validation: moving-time accumulates only strictly above the 0.5 m/s threshold
/// (AC-9/AC-10/AC-11), and ETA is withheld until enough moving time has accumulated, then
/// reported as remaining distance ÷ average pace so far (AC-7/AC-8).
final class RideTrackerMovingTimeETATests: XCTestCase {

    private let totalRouteDistanceMeters = 10_000.0

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(
                latitude: 52.0, longitude: 13.1, elevationMeters: nil, cumulativeDistanceMeters: totalRouteDistanceMeters),
        ]
    }

    /// A fix exactly on the route (0 off-route meters) at a given fraction along it, so every
    /// fix in these tests stays in-corridor and only the moving-time/ETA logic is exercised.
    private func fix(fraction: Double, speed: Double, time: TimeInterval) -> LocationFix {
        LocationFix(
            latitude: 52.0, longitude: 13.0 + fraction * 0.1, speedMetersPerSecond: speed,
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
    func testMovingTimeAccumulatesWhileSpeedIsClearlyAboveThreshold() async {
        let tracker = tracker(fixes: [fix(fraction: 0, speed: 5, time: 0), fix(fraction: 0.01, speed: 5, time: 10)])

        await tracker.start()

        XCTAssertEqual(tracker.movingTimeSeconds, 10, accuracy: 0.001)
    }

    @MainActor
    func testMovingTimeDoesNotAccumulateAtExactlyTheThreshold() async {
        let tracker = tracker(fixes: [fix(fraction: 0, speed: 5, time: 0), fix(fraction: 0.01, speed: 0.5, time: 10)])

        await tracker.start()

        XCTAssertEqual(tracker.movingTimeSeconds, 0, accuracy: 0.001)
    }

    @MainActor
    func testMovingTimeDoesNotAccumulateBelowTheThreshold() async {
        let tracker = tracker(fixes: [fix(fraction: 0, speed: 5, time: 0), fix(fraction: 0.01, speed: 0.2, time: 10)])

        await tracker.start()

        XCTAssertEqual(tracker.movingTimeSeconds, 0, accuracy: 0.001)
    }

    @MainActor
    func testNoETAIsReportedBeforeTheMinimumMovingTimeIsReached() async {
        let fixes = [
            fix(fraction: 0, speed: 5, time: 0),
            fix(fraction: 0.1, speed: 5, time: 10),
            fix(fraction: 0.2, speed: 5, time: 20),
        ]
        let tracker = tracker(fixes: fixes)

        await tracker.start()

        XCTAssertEqual(tracker.movingTimeSeconds, 20, accuracy: 0.001, "precondition: still below the minimum")
        XCTAssertNil(tracker.etaSeconds)
    }

    @MainActor
    func testPaceBasedETAIsReportedAfterTheMinimumMovingTimeIsReached() async {
        let fixes = [
            fix(fraction: 0, speed: 5, time: 0),
            fix(fraction: 0.1, speed: 5, time: 10),
            fix(fraction: 0.2, speed: 5, time: 20),
            fix(fraction: 0.3, speed: 5, time: 30),
            fix(fraction: 0.4, speed: 5, time: 40),
        ]
        let tracker = tracker(fixes: fixes)

        await tracker.start()

        // movingTimeSeconds=40, distanceAlongRouteMeters=4,000m; pace 0.01 s/m; remaining 6,000m.
        XCTAssertEqual(tracker.movingTimeSeconds, 40, accuracy: 0.001, "precondition: past the minimum")
        XCTAssertNotNil(tracker.etaSeconds)
        XCTAssertEqual(tracker.etaSeconds ?? -1, 60, accuracy: 0.5)
    }
}

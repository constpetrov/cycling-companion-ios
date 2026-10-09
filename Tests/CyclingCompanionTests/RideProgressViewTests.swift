import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.1 validation (AC-14/15/16/17): constructing the view with a `RideTracker` in
/// various states (no ETA yet, ETA present, sensor data present/absent) exposes the
/// corresponding display values.
final class RideProgressViewTests: XCTestCase {

    private let totalRouteDistanceMeters = 10_000.0

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(
                latitude: 52.0, longitude: 13.1, elevationMeters: nil, cumulativeDistanceMeters: totalRouteDistanceMeters),
        ]
    }

    private func fix(fraction: Double, speed: Double, time: TimeInterval) -> LocationFix {
        LocationFix(
            latitude: 52.0, longitude: 13.0 + fraction * 0.1, speedMetersPerSecond: speed,
            timestamp: Date(timeIntervalSince1970: time))
    }

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func tracker(fixes: [LocationFix], samples: [SensorSample] = []) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: route(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: samples),
            clock: ReplayClock(), rideStore: freshRideStore())
    }

    @MainActor
    func testDisplaysDistanceDoneAndRemaining() async {
        let tracker = tracker(fixes: [fix(fraction: 0.3, speed: 5, time: 0)])
        await tracker.start()
        let view = RideProgressView(rideTracker: tracker)

        XCTAssertEqual(view.distanceDoneMeters, 3_000, accuracy: 1.0)
        XCTAssertEqual(view.distanceRemainingMeters, 7_000, accuracy: 1.0)
    }

    @MainActor
    func testNoETAIsDisplayedAsNilBeforeTheMinimumMovingTimeIsReached() async {
        let fixes = [fix(fraction: 0, speed: 5, time: 0), fix(fraction: 0.1, speed: 5, time: 10)]
        let tracker = tracker(fixes: fixes)
        await tracker.start()
        let view = RideProgressView(rideTracker: tracker)

        XCTAssertNil(view.etaSeconds)
    }

    @MainActor
    func testETAIsDisplayedAfterTheMinimumMovingTimeIsReached() async {
        let fixes = [
            fix(fraction: 0, speed: 5, time: 0),
            fix(fraction: 0.1, speed: 5, time: 10),
            fix(fraction: 0.2, speed: 5, time: 20),
            fix(fraction: 0.3, speed: 5, time: 30),
        ]
        let tracker = tracker(fixes: fixes)
        await tracker.start()
        let view = RideProgressView(rideTracker: tracker)

        XCTAssertNotNil(view.etaSeconds)
        XCTAssertEqual(view.etaSeconds, tracker.etaSeconds)
    }

    @MainActor
    func testCurrentSpeedIsNilBeforeTheFirstLocationUpdate() async {
        let tracker = tracker(fixes: [])
        await tracker.start()
        let view = RideProgressView(rideTracker: tracker)

        XCTAssertNil(view.currentSpeedMetersPerSecond)
    }

    @MainActor
    func testSensorDataIsDisplayedWhenAvailable() async {
        let samples = [SensorSample(heartRateBPM: 140, cadenceRPM: 85, timestamp: Date(timeIntervalSince1970: 0))]
        let tracker = tracker(fixes: [], samples: samples)
        await tracker.start()
        let view = RideProgressView(rideTracker: tracker)

        XCTAssertEqual(view.currentHeartRateBPM, 140)
        XCTAssertEqual(view.currentCadenceRPM, 85)
    }

    @MainActor
    func testSensorDataIsNilAsAPlaceholderWhenUnavailable() async {
        let tracker = tracker(fixes: [], samples: [])
        await tracker.start()
        let view = RideProgressView(rideTracker: tracker)

        XCTAssertNil(view.currentHeartRateBPM)
        XCTAssertNil(view.currentCadenceRPM)
    }
}

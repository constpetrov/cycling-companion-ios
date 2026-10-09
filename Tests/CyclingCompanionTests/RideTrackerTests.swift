import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// AC-1, AC-12, AC-13 in spec/criteria.md (task-2.1): the walking-skeleton RideTracker
/// consumes both sources and publishes the latest reading from each, with no stale/zero
/// substitution on a sensor dropout.
final class RideTrackerTests: XCTestCase {

    private func straightRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.01, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 1_113),
        ]
    }

    /// Each test gets its own throwaway store file — task-2.1's tests predate checkpointing
    /// (task-2.4) and don't assert anything about it, so a fresh temp file is all that's needed
    /// to satisfy `RideTracker`'s constructor.
    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    func testStartConsumesLocationUpdatesAndPublishesTheLatestFix() async {
        let fixes = [
            LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 2.0, timestamp: Date(timeIntervalSince1970: 0)),
            LocationFix(latitude: 52.001, longitude: 13.0, speedMetersPerSecond: 3.0, timestamp: Date(timeIntervalSince1970: 10)),
        ]
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: freshRideStore())

        XCTAssertNil(tracker.latestFix)
        await tracker.start()

        XCTAssertEqual(tracker.latestFix?.latitude, fixes.last?.latitude)
        XCTAssertEqual(tracker.latestFix?.speedMetersPerSecond, fixes.last?.speedMetersPerSecond)
    }

    @MainActor
    func testSensorDropoutIsPublishedAsNilNotAStaleValue() async {
        let samples = [
            SensorSample(heartRateBPM: 140, cadenceRPM: 85, timestamp: Date(timeIntervalSince1970: 0)),
            SensorSample(heartRateBPM: nil, cadenceRPM: 85, timestamp: Date(timeIntervalSince1970: 1)),
        ]
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: samples),
            clock: ReplayClock(), rideStore: freshRideStore())

        await tracker.start()

        XCTAssertNil(tracker.currentHeartRateBPM, "a dropout must not leave the prior reading (140) stuck")
        XCTAssertEqual(tracker.currentCadenceRPM, 85)
    }
}

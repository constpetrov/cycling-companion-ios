import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.4 validation (RULE-12): after each accepted location update, `RideStore` contains a
/// `PersistedRide` for this ride with no `endTime` and the latest accumulated stats.
final class RideTrackerCheckpointingTests: XCTestCase {

    private func straightRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: nil, cumulativeDistanceMeters: 10_000),
        ]
    }

    private func fix(fraction: Double, speed: Double, time: TimeInterval) -> LocationFix {
        LocationFix(
            latitude: 52.0, longitude: 13.0 + fraction * 0.1, speedMetersPerSecond: speed,
            timestamp: Date(timeIntervalSince1970: time))
    }

    private func tempStoreFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    @MainActor
    func testEveryAcceptedLocationUpdateCheckpointsAnUnfinishedPersistedRide() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let fixes = [
            fix(fraction: 0, speed: 5, time: 0),
            fix(fraction: 0.1, speed: 5, time: 10),
            fix(fraction: 0.2, speed: 5, time: 20),
        ]
        let tracker = RideTracker(
            rideId: "ride-42", routeId: "route-7", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: store)

        await tracker.start()

        let checkpointed = try await store.fetch(rideId: "ride-42")
        XCTAssertNotNil(checkpointed, "a checkpoint must exist after accepted location updates")
        XCTAssertNil(checkpointed?.endTime, "RideTracker must never set endTime — that's RideRecorder's job (RULE-11)")
        XCTAssertEqual(checkpointed?.routeId, "route-7")
        XCTAssertEqual(checkpointed?.totalDistanceMeters ?? -1, tracker.distanceAlongRouteMeters, accuracy: 0.01)
        XCTAssertEqual(checkpointed?.totalMovingTimeSeconds ?? -1, tracker.movingTimeSeconds, accuracy: 0.01)
        XCTAssertEqual(checkpointed?.track.count, fixes.count)
    }

    @MainActor
    func testCheckpointReflectsStateAfterOffRouteAndSensorDropoutFixes() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        // The second fix is 1,000m off-route (well beyond the 50m corridor), so
        // distanceAlongRouteMeters must freeze at the first fix's value while the checkpoint
        // still records both raw fixes.
        let fixes = [
            fix(fraction: 0.1, speed: 5, time: 0),
            LocationFix(latitude: 61.0, longitude: 13.0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 10)),
        ]
        let tracker = RideTracker(
            rideId: "ride-99", routeId: "route-7", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: store)

        await tracker.start()

        let checkpointed = try await store.fetch(rideId: "ride-99")
        XCTAssertEqual(
            checkpointed?.totalDistanceMeters ?? -1, 1_000, accuracy: 0.5, "frozen at the in-corridor fix's distance")
        XCTAssertEqual(checkpointed?.track.count, 2, "the off-route fix is still checkpointed in the raw track")
    }

    /// A checkpoint requested after the ride started finishing (a late suggestion answer, or the
    /// cancelled fix loop) must not write, or it could overwrite the finished ride.
    @MainActor
    func testNoCheckpointIsWrittenAfterCheckpointingStops() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let tracker = RideTracker(
            rideId: "ride-42", routeId: "route-7", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: store)

        await tracker.stopCheckpointing()
        await tracker.checkpointNow()

        let stored = try await store.fetch(rideId: "ride-42")
        XCTAssertNil(stored)
    }

    @MainActor
    func testStopCheckpointingWaitsForTheCheckpointInFlight() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let tracker = RideTracker(
            rideId: "ride-42", routeId: "route-7", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: store)

        async let inFlight: Void = tracker.checkpointNow()
        await Task.yield()
        await tracker.stopCheckpointing()
        let storedWhenStopped = try await store.fetch(rideId: "ride-42")
        await inFlight

        // Either the in-flight checkpoint finished before stopCheckpointing returned, or it never
        // wrote; nothing may land afterwards.
        let storedAfterwards = try await store.fetch(rideId: "ride-42")
        XCTAssertEqual(storedWhenStopped?.id, storedAfterwards?.id)
    }
}

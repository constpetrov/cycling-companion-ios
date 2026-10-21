import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.1 validation (RULE-14, AC-20): constructs a fresh `RideTracker`, seeds `RideStore`
/// with a checkpointed `PersistedRide` that has no `endTime`, calls `resumeIfNeeded(from:)`,
/// and asserts the tracker's state matches the checkpoint — not a real process
/// termination/relaunch, which XCTest cannot straightforwardly drive.
final class RideTrackerResumeTests: XCTestCase {

    private func straightRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: nil, cumulativeDistanceMeters: 10_000),
        ]
    }

    private func tempStoreFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    @MainActor
    private func freshTracker(rideStore: RideStore) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: straightRoute(),
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
    }

    @MainActor
    func testResumeIfNeededRehydratesStateFromAnUnfinishedCheckpoint() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let track = [
            PersistedRideSample(
                latitude: 52.0, longitude: 13.03, speedMetersPerSecond: 5, heartRateBPM: 140, cadenceRPM: 85,
                timestamp: Date(timeIntervalSince1970: 30))
        ]
        try await store.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 3_000, totalMovingTimeSeconds: 600, track: track))
        let tracker = freshTracker(rideStore: store)

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 0, "precondition: a fresh tracker starts at zero")

        try await tracker.resumeIfNeeded(from: store)

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 3_000, accuracy: 0.01)
        XCTAssertEqual(tracker.movingTimeSeconds, 600, accuracy: 0.01)
        XCTAssertEqual(tracker.track.count, 1)
        XCTAssertEqual(tracker.track.first?.heartRateBPM, 140)
    }

    /// Past the 30s ETA threshold, resuming must also restore a reportable ETA — not leave it
    /// stuck at the fresh tracker's default `nil`.
    @MainActor
    func testResumeIfNeededRecomputesETAWhenPastTheMinimumMovingTime() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        try await store.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 3_000, totalMovingTimeSeconds: 600, track: []))
        let tracker = freshTracker(rideStore: store)

        try await tracker.resumeIfNeeded(from: store)

        // remaining 7,000m * (600s / 3,000m) = 1,400s.
        XCTAssertEqual(tracker.etaSeconds ?? -1, 1_400, accuracy: 0.01)
    }

    @MainActor
    func testResumeIfNeededIsANoOpWhenNoUnfinishedCheckpointExists() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        try await store.persist(
            PersistedRide(
                id: "ride-0", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 100), totalDistanceMeters: 5_000, totalMovingTimeSeconds: 100,
                track: []))
        let tracker = freshTracker(rideStore: store)

        try await tracker.resumeIfNeeded(from: store)

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 0, "a completed ride (endTime set) must not be resumed")
        XCTAssertEqual(tracker.movingTimeSeconds, 0)
        XCTAssertTrue(tracker.track.isEmpty)
    }

    @MainActor
    func testDoesNotLoadAnotherUnfinishedRidesCheckpoint() async throws {
        let store = RideStore(fileURL: tempStoreFileURL())
        try await store.persist(PersistedRide(
            id: "other-ride", routeId: "other-route", startTime: Date(), endTime: nil,
            totalDistanceMeters: 9_000, totalMovingTimeSeconds: 600, track: []))
        let tracker = freshTracker(rideStore: store)

        try await tracker.resumeIfNeeded(from: store)

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 0)
        XCTAssertTrue(tracker.track.isEmpty)
    }
}

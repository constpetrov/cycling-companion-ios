import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.2 validation (RULE-9/RULE-16 in spec/rules.md, AC-17).
final class RideResumerTests: XCTestCase {

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    private func freshRouteStore() -> RouteStore {
        RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func makeResumer(rideStore: RideStore, routeStore: RouteStore, rideCoordinator: RideCoordinator) -> RideResumer {
        RideResumer(
            rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator, decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()))
    }

    @MainActor
    func testNoUnfinishedRideSettlesOnHome() async throws {
        let rideStore = freshRideStore()
        let routeStore = freshRouteStore()
        let rideCoordinator = RideCoordinator()
        let resumer = makeResumer(rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator)

        await resumer.resumeIfNeeded()

        XCTAssertNil(rideCoordinator.activeRide)
    }

    @MainActor
    func testAnUnfinishedRideResumesWithMatchingCheckpointState() async throws {
        let rideStore = freshRideStore()
        let routeStore = freshRouteStore()
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
                PersistedPointInput(
                    latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
            ], pois: [], status: "ready")
        let checkpointTrack = [
            PersistedRideSample(
                latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, heartRateBPM: nil, cadenceRPM: nil,
                timestamp: Date(timeIntervalSince1970: 1_000))
        ]
        try await rideStore.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 2_500, totalMovingTimeSeconds: 600, track: checkpointTrack))
        let rideCoordinator = RideCoordinator()
        let resumer = makeResumer(rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator)

        await resumer.resumeIfNeeded()

        let liveRide = rideCoordinator.activeRide
        guard let tracker = liveRide?.tracker else {
            XCTFail("expected a resumed live ride screen")
            return
        }
        XCTAssertEqual(tracker.rideId, "ride-1")
        XCTAssertEqual(tracker.routeId, "route-1")
        XCTAssertEqual(tracker.distanceAlongRouteMeters, 2_500)
        XCTAssertEqual(tracker.movingTimeSeconds, 600)
        XCTAssertEqual(tracker.track.count, 1)

        await resumer.resumeIfNeeded()
        let resumedAgain = rideCoordinator.activeRide
        guard resumedAgain != nil else {
            return XCTFail("expected the same active ride")
        }
        XCTAssertTrue(resumedAgain?.tracker === tracker, "a second launch task must not spawn another session")
        XCTAssertFalse(liveRide?.sessionTask.isCancelled ?? true)

        liveRide?.trackingTask.cancel()
        liveRide?.sessionTask.cancel()
    }

    @MainActor
    func testAnUnfinishedRideWithNoMatchingRouteFallsBackToHomeInsteadOfStickingOnTheSpinner() async throws {
        let rideStore = freshRideStore()
        let routeStore = freshRouteStore() // deliberately empty: no "route-1" persisted
        try await rideStore.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 0, totalMovingTimeSeconds: 0, track: []))
        let rideCoordinator = RideCoordinator()
        let resumer = makeResumer(rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator)

        await resumer.resumeIfNeeded()

        XCTAssertNil(rideCoordinator.activeRide, "an unresolvable checkpoint must leave the app on Home")
        XCTAssertEqual(rideCoordinator.phase, .idle, "and must release the resume lock")
    }

    /// Was `AppRouterTests.testAFinishedRideDoesNotCountAsUnfinished` (detection moved here).
    @MainActor
    func testAFinishedRideIsNotResumed() async throws {
        let rideStore = freshRideStore()
        try await rideStore.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 100), totalDistanceMeters: 1_000, totalMovingTimeSeconds: 60,
                track: []))
        let rideCoordinator = RideCoordinator()
        let resumer = makeResumer(rideStore: rideStore, routeStore: freshRouteStore(), rideCoordinator: rideCoordinator)

        await resumer.resumeIfNeeded()

        XCTAssertNil(rideCoordinator.activeRide)
    }
}

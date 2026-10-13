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
    private func makeResumer(rideStore: RideStore, routeStore: RouteStore, appRouter: AppRouter) -> RideResumer {
        RideResumer(
            rideStore: rideStore, routeStore: routeStore, appRouter: appRouter, decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()))
    }

    @MainActor
    func testNoUnfinishedRideSettlesOnHome() async throws {
        let rideStore = freshRideStore()
        let routeStore = freshRouteStore()
        let appRouter = AppRouter()
        let resumer = makeResumer(rideStore: rideStore, routeStore: routeStore, appRouter: appRouter)

        await resumer.resumeIfNeeded()

        XCTAssertEqual(appRouter.currentScreen, .home)
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
        let appRouter = AppRouter()
        let resumer = makeResumer(rideStore: rideStore, routeStore: routeStore, appRouter: appRouter)

        await resumer.resumeIfNeeded()

        guard case .liveRide(let liveRide) = appRouter.currentScreen, let tracker = liveRide?.tracker else {
            XCTFail("expected a resumed live ride screen")
            return
        }
        XCTAssertEqual(tracker.rideId, "ride-1")
        XCTAssertEqual(tracker.routeId, "route-1")
        XCTAssertEqual(tracker.distanceAlongRouteMeters, 2_500)
        XCTAssertEqual(tracker.movingTimeSeconds, 600)
        XCTAssertEqual(tracker.track.count, 1)

        liveRide?.trackingTask.cancel()
        liveRide?.sessionTask.cancel()
    }
}

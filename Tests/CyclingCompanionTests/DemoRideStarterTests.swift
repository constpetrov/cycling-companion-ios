import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.3 validation (RULE-1/RULE-7/RULE-9/RULE-15 in spec/rules.md, AC-21/AC-22/AC-23/AC-25).
final class DemoRideStarterTests: XCTestCase {

    private func freshRouteStore() -> RouteStore {
        RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    private func freshPointer(routeId: String) -> CurrentRoutePointer {
        var pointer = CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        pointer.routeId = routeId
        return pointer
    }

    @MainActor
    private func makeStarter(
        routeStore: RouteStore, pointer: CurrentRoutePointer, rideCoordinator: RideCoordinator, decisionLog: DecisionLog
    ) -> DemoRideStarter {
        return DemoRideStarter(
            routeStore: routeStore,
            rideStore: RideStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")),
            pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: decisionLog))
    }

    @MainActor
    func testDemoUsesRouteSelectedAtStartInsteadOfBundledCoordinates() async throws {
        let store = freshRouteStore()
        try await store.persist(
            routeId: "selected", hash: "selected-hash", totalDistanceMeters: 100, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52.1, longitude: 4.3, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52.101, longitude: 4.3, elevationMeters: nil, cumulativeDistanceMeters: 100),
            ], pois: [], status: "ready")
        let pointer = freshPointer(routeId: "previous-route")
        let coordinator = RideCoordinator()
        let starter = makeStarter(
            routeStore: store, pointer: pointer, rideCoordinator: coordinator, decisionLog: DecisionLog())
        // The starter holds a copy of the pointer, whose backing defaults are shared.
        pointer.routeId = "selected"

        let session = await starter.startDemoRide(speed: 20)
        XCTAssertNotNil(session)
        let ride = try XCTUnwrap(coordinator.activeRide)
        defer { coordinator.end(ride) }
        for _ in 0..<100 {
            if ride.tracker.latestFix != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let fix = try XCTUnwrap(ride.tracker.latestFix)
        XCTAssertEqual(ride.tracker.routeId, "selected")
        XCTAssertEqual(fix.longitude, 4.3, accuracy: 0.000001)
        XCTAssertEqual(fix.latitude, 52.1, accuracy: 0.0011)
        XCTAssertLessThan(abs(fix.timestamp.timeIntervalSinceNow), 30)
        XCTAssertEqual(try XCTUnwrap(ride.tracker.latestOffRouteMeters), 0, accuracy: 1)
    }

    @MainActor
    func testDemoDoesNotStartWithoutCurrentRoute() async {
        let coordinator = RideCoordinator()
        let starter = makeStarter(
            routeStore: freshRouteStore(), pointer: freshPointer(routeId: "missing"),
            rideCoordinator: coordinator, decisionLog: DecisionLog())

        let session = await starter.startDemoRide(speed: 1)

        XCTAssertNil(session)
        XCTAssertNil(coordinator.activeRide)
    }

    @MainActor
    func testStartDemoRideNavigatesToTheLiveRideScreen() async throws {
        let routeStore = freshRouteStore()
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
                PersistedPointInput(
                    latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
            ], pois: [], status: "ready")
        let pointer = freshPointer(routeId: "route-1")
        let rideCoordinator = RideCoordinator()
        let starter = makeStarter(routeStore: routeStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: DecisionLog())

        await starter.startDemoRide(speed: 20)

        let liveRide = rideCoordinator.activeRide
        guard liveRide != nil else {
            XCTFail("expected the live ride screen")
            return
        }
        XCTAssertNotNil(liveRide?.tracker)

        liveRide?.trackingTask.cancel()
        liveRide?.sessionTask.cancel()
    }

    @MainActor
    func testConcurrentDemoStartsCreateOnlyOneSession() async throws {
        let routeStore = freshRouteStore()
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 1_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ], pois: [], status: "ready")
        let router = RideCoordinator()
        let starter = makeStarter(
            routeStore: routeStore, pointer: freshPointer(routeId: "route-1"), rideCoordinator: router,
            decisionLog: DecisionLog())

        let first = Task { @MainActor in await starter.startDemoRide(speed: 20) }
        let second = Task { @MainActor in await starter.startDemoRide(speed: 20) }
        let sessions = [await first.value, await second.value].compactMap { $0 }

        XCTAssertEqual(sessions.count, 1)
        if let ride = router.activeRide { router.end(ride) }
    }

    @MainActor
    func testStartDemoRideFedThroughTheReplayDriverProducesDecisionLogEntries() async throws {
        let routeStore = freshRouteStore()
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
                PersistedPointInput(
                    latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
            ], pois: [], status: "ready")
        let pointer = freshPointer(routeId: "route-1")
        let rideCoordinator = RideCoordinator()
        let decisionLog = DecisionLog()
        let starter = makeStarter(routeStore: routeStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog)

        await starter.startDemoRide(speed: 20)

        guard let liveRide = rideCoordinator.activeRide else {
            XCTFail("expected the live ride screen")
            return
        }

        // Give the replay driver a moment to yield its first fix, then force an immediate
        // cycle rather than waiting out the (speed-scaled) cadence.
        try await Task.sleep(nanoseconds: 300_000_000)
        await liveRide.session.forceNextCheck()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(decisionLog.advisorDecisions.isEmpty, "the same chain a live-source RideSession drives must log through the replay-driven one too")

        liveRide.trackingTask.cancel()
        liveRide.sessionTask.cancel()
    }
}

import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.1 validation (RULE-9/RULE-16 in spec/rules.md, AC-1).
final class AppRouterTests: XCTestCase {

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    func testStartsOnHomeBeforeDeterminingTheInitialScreen() {
        let router = AppRouter()

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testNoUnfinishedRideSettlesOnHome() async throws {
        let store = freshRideStore()
        let router = AppRouter()

        await router.determineInitialScreen(rideStore: store)

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testAnUnfinishedRideSettlesOnTheLiveRideScreen() async throws {
        let store = freshRideStore()
        try await store.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 1_000, totalMovingTimeSeconds: 60, track: []))
        let router = AppRouter()

        await router.determineInitialScreen(rideStore: store)

        XCTAssertEqual(router.currentScreen, .liveRide(nil))
    }

    @MainActor
    func testAFinishedRideDoesNotCountAsUnfinished() async throws {
        let store = freshRideStore()
        try await store.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 100), totalDistanceMeters: 1_000, totalMovingTimeSeconds: 60,
                track: []))
        let router = AppRouter()

        await router.determineInitialScreen(rideStore: store)

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testShowMutatesCurrentScreen() {
        let router = AppRouter()

        router.show(.liveRide(nil))

        XCTAssertEqual(router.currentScreen, .liveRide(nil))
    }

    @MainActor
    private func liveRide() -> LiveRide {
        let tracker = RideTracker(
            rideId: UUID().uuidString, routeId: "route-1", startTime: Date(), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: freshRideStore())
        let log = DecisionLog()
        let session = RideSession(
            rideTracker: tracker, featureEngine: FeatureEngine(rideTracker: tracker, route: [], clock: ReplayClock()),
            clock: ReplayClock(), routeId: "route-1",
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            decisionLog: log, notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log))
        return LiveRide(tracker: tracker, session: session, trackingTask: Task {}, sessionTask: Task {})
    }

    @MainActor
    func testReplacingLiveRideCancelsBothOldTasks() {
        let router = AppRouter()
        let first = liveRide()
        let second = liveRide()
        router.show(.liveRide(first))

        router.show(.liveRide(second))

        XCTAssertTrue(first.trackingTask.isCancelled)
        XCTAssertTrue(first.sessionTask.isCancelled)
        XCTAssertFalse(second.sessionTask.isCancelled)
        router.show(.home)
        XCTAssertTrue(second.trackingTask.isCancelled)
        XCTAssertTrue(second.sessionTask.isCancelled)
    }

    @MainActor
    func testPlaceholderCannotDiscardAnActiveRide() {
        let router = AppRouter()
        let ride = liveRide()
        router.show(.liveRide(ride))

        router.show(.liveRide(nil))

        XCTAssertEqual(router.currentScreen, .liveRide(ride))
        XCTAssertFalse(ride.sessionTask.isCancelled)
        router.show(.home)
    }
}

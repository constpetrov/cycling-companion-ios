import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// `AppRouter` is navigation only since milestone 7 (RULE-2): ride state and its tests moved to
/// `RideCoordinatorTests`; unfinished-ride detection moved to `RideResumerTests`.
final class AppRouterTests: XCTestCase {

    @MainActor
    func testStartsOnHome() {
        let router = AppRouter()

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testShowMutatesCurrentScreen() {
        let router = AppRouter()

        router.show(.corridorMap)

        XCTAssertEqual(router.currentScreen, .corridorMap)
    }

    /// AC-1/AC-2: navigating while a ride is active never stops its tracking or advisor loop.
    @MainActor
    func testNavigatingDuringAnActiveRideKeepsItsTasksRunning() {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
        let log = DecisionLog()
        let session = RideSession(
            rideTracker: tracker, featureEngine: FeatureEngine(rideTracker: tracker, route: [], clock: ReplayClock()),
            clock: ReplayClock(), routeId: "route-1",
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            decisionLog: log, notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log))
        let ride = LiveRide(
            tracker: tracker, session: session,
            trackingTask: Task { try? await Task.sleep(nanoseconds: .max) },
            sessionTask: Task { try? await Task.sleep(nanoseconds: .max) })
        let rideCoordinator = RideCoordinator()
        rideCoordinator.activate(ride)
        let router = AppRouter()

        router.show(.corridorMap)
        router.show(.home)

        XCTAssertFalse(ride.trackingTask.isCancelled)
        XCTAssertFalse(ride.sessionTask.isCancelled)
        XCTAssertTrue(rideCoordinator.activeRide?.tracker === tracker)
        rideCoordinator.end(ride)
    }
}

import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.3 validation (RULE-9/RULE-10/RULE-16 in spec/rules.md, AC-18/AC-19).
final class AppDelegateNotificationTests: XCTestCase {

    @MainActor
    private func freshRideTracker() -> RideTracker {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
    }

    @MainActor
    func testTapWhileOnHomeNavigatesToTheLiveRideScreen() {
        let appRouter = AppRouter()
        appRouter.show(.home)
        let delegate = AppDelegate()
        delegate.appRouter = appRouter

        delegate.handleNotificationTap()

        guard case .liveRide = appRouter.currentScreen else {
            XCTFail("expected the live ride screen")
            return
        }
    }

    @MainActor
    func testTapWhileOnCorridorMapNavigatesToTheLiveRideScreen() {
        let appRouter = AppRouter()
        appRouter.show(.corridorMap)
        let delegate = AppDelegate()
        delegate.appRouter = appRouter

        delegate.handleNotificationTap()

        guard case .liveRide = appRouter.currentScreen else {
            XCTFail("expected the live ride screen")
            return
        }
    }

    @MainActor
    func testTapWhileAlreadyOnARealLiveRideDoesNotDiscardTheTracker() {
        let appRouter = AppRouter()
        let tracker = freshRideTracker()
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let session = RideSession(
            rideTracker: tracker, featureEngine: FeatureEngine(rideTracker: tracker, route: [], clock: ReplayClock()),
            clock: ReplayClock(), routeId: "route-1", routeStore: routeStore, decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()))
        let trackingTask = Task<Void, Never> {}
        let sessionTask = Task<Void, Never> {}
        appRouter.show(
            .liveRide(LiveRide(tracker: tracker, session: session, trackingTask: trackingTask, sessionTask: sessionTask)))
        let delegate = AppDelegate()
        delegate.appRouter = appRouter

        delegate.handleNotificationTap()

        guard case .liveRide(let liveRide) = appRouter.currentScreen else {
            XCTFail("expected the live ride screen")
            return
        }
        XCTAssertTrue(liveRide?.tracker === tracker, "an already-resumed/started ride's tracker must not be discarded")
    }

    @MainActor
    func testTapWithNoAppRouterSetIsANoOp() {
        let delegate = AppDelegate()

        delegate.handleNotificationTap() // must not crash
    }
}

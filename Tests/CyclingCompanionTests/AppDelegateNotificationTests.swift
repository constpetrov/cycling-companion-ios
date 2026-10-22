import RoutePersistence
import UserNotifications
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

    /// AC-76 (milestone 7): with no ride, a tap leaves the app where it is — no placeholder.
    @MainActor
    func testTapWhileOnHomeWithNoRideStaysOnHome() {
        let appRouter = AppRouter()
        let delegate = AppDelegate()
        delegate.appRouter = appRouter

        delegate.handleNotificationTap()

        XCTAssertEqual(appRouter.currentScreen, .home)
    }

    @MainActor
    func testTapWhileOnCorridorMapWithNoRideStaysOnTheCorridorMap() {
        let appRouter = AppRouter()
        appRouter.show(.corridorMap)
        let delegate = AppDelegate()
        delegate.appRouter = appRouter

        delegate.handleNotificationTap()

        XCTAssertEqual(appRouter.currentScreen, .corridorMap)
    }

    @MainActor
    func testTapDuringAnActiveRideDoesNotDiscardIt() {
        let tracker = freshRideTracker()
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let session = RideSession(
            rideTracker: tracker, featureEngine: FeatureEngine(rideTracker: tracker, route: [], clock: ReplayClock()),
            clock: ReplayClock(), routeId: "route-1", routeStore: routeStore, decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()))
        let ride = LiveRide(
            tracker: tracker, session: session,
            trackingTask: Task { try? await Task.sleep(nanoseconds: .max) },
            sessionTask: Task { try? await Task.sleep(nanoseconds: .max) })
        let rideCoordinator = RideCoordinator()
        rideCoordinator.activate(ride)
        let delegate = AppDelegate()
        delegate.appRouter = AppRouter()

        delegate.handleNotificationTap()

        XCTAssertTrue(rideCoordinator.activeRide?.tracker === tracker, "the active ride must not be discarded")
        XCTAssertFalse(ride.sessionTask.isCancelled)
        rideCoordinator.end(ride)
    }

    @MainActor
    func testTapWithNoAppRouterSetIsANoOp() {
        let delegate = AppDelegate()

        delegate.handleNotificationTap() // must not crash
    }

    /// Without a `willPresent` delegate method iOS drops notifications while the app is in the
    /// foreground, which is where the rider usually is during a ride.
    @MainActor
    func testForegroundNotificationsAreShownAsABannerWithSound() {
        let options = AppDelegate.foregroundPresentationOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.sound))
    }

    @MainActor
    func testAppDelegateImplementsWillPresent() {
        let selector = #selector(
            UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        XCTAssertTrue(AppDelegate().responds(to: selector))
    }
}

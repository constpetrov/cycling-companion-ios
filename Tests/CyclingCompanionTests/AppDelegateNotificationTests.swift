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

    private func userInfo(stopId: String) -> [AnyHashable: Any] {
        ["stopId": stopId, "latitude": 52.0, "longitude": 13.0]
    }

    @MainActor
    private func delegate(phase: RideCoordinator.Phase, launchResumeFinished: Bool) -> (AppDelegate, AppRouter) {
        let router = AppRouter()
        if launchResumeFinished { router.launchResumeFinished(ridePhase: .idle) }
        let coordinator = RideCoordinator()
        if phase == .preparing { _ = coordinator.beginPreparingRide() }
        if phase == .resuming { _ = coordinator.beginPreparingRide(resuming: true) }
        let delegate = AppDelegate()
        delegate.appRouter = router
        delegate.rideCoordinator = coordinator
        return (delegate, router)
    }

    func testAStopLinkIsParsedFromTheNotificationPayload() {
        XCTAssertEqual(StopLink(userInfo: ["stopId": "1001"])?.stopId, 1001)
        XCTAssertNil(StopLink(userInfo: ["stopId": "not-a-number"]))
        XCTAssertNil(StopLink(userInfo: [:]))
    }

    /// AC-76: no ride and the launch resume already done → the app stays where it is.
    @MainActor
    func testAStaleTapIsDroppedAndNothingNavigates() {
        let (delegate, router) = delegate(phase: .idle, launchResumeFinished: true)
        router.open(.corridorMap(routeId: "route-1"))

        delegate.handleNotificationTap(userInfo: userInfo(stopId: "1001"))

        XCTAssertNil(router.pendingStopLink)
        XCTAssertEqual(router.path, [.corridorMap(routeId: "route-1")])
    }

    /// AC-71: a tap during an active ride is held for the dashboard to open.
    @MainActor
    func testATapDuringAnActiveRideIsHeldForTheDashboard() {
        let router = AppRouter()
        router.launchResumeFinished(ridePhase: .idle)
        let coordinator = RideCoordinator()
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
        let ride = LiveRide(tracker: tracker, session: session, trackingTask: Task {}, sessionTask: Task {})
        coordinator.activate(ride)
        let delegate = AppDelegate()
        delegate.appRouter = router
        delegate.rideCoordinator = coordinator

        delegate.handleNotificationTap(userInfo: userInfo(stopId: "1001"))

        XCTAssertEqual(router.takePendingStopLink(), StopLink(stopId: 1001))
        XCTAssertNil(router.pendingStopLink, "taken once")
        XCTAssertTrue(coordinator.activeRide?.tracker === tracker, "the ride is untouched")
        coordinator.end(ride)
    }

    /// AC-74: a tap while a ride is being prepared waits for it.
    @MainActor
    func testATapWhileARideIsBeingPreparedIsHeld() {
        let (delegate, router) = delegate(phase: .preparing, launchResumeFinished: true)

        delegate.handleNotificationTap(userInfo: userInfo(stopId: "1001"))

        XCTAssertEqual(router.pendingStopLink, StopLink(stopId: 1001))
    }

    /// AC-75: on a cold launch the tap arrives before the resume; it's kept until the resume has
    /// run, then kept if a ride resumed and dropped if not.
    @MainActor
    func testAColdLaunchTapWaitsForTheResume() {
        let (delegate, router) = delegate(phase: .idle, launchResumeFinished: false)
        delegate.handleNotificationTap(userInfo: userInfo(stopId: "1001"))
        XCTAssertEqual(router.pendingStopLink, StopLink(stopId: 1001))

        router.launchResumeFinished(ridePhase: .active)
        XCTAssertEqual(router.pendingStopLink, StopLink(stopId: 1001), "a ride resumed: keep it")

        let (otherDelegate, otherRouter) = self.delegate(phase: .idle, launchResumeFinished: false)
        otherDelegate.handleNotificationTap(userInfo: userInfo(stopId: "1001"))
        otherRouter.launchResumeFinished(ridePhase: .idle)
        XCTAssertNil(otherRouter.pendingStopLink, "nothing resumed: the tap is stale")
    }

    @MainActor
    func testATapWithNoRouterSetIsANoOp() {
        AppDelegate().handleNotificationTap(userInfo: userInfo(stopId: "1001"))  // must not crash
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

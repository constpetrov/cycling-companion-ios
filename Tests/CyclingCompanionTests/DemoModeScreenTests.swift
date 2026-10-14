import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.2/task-4.4 validation (RULE-14/RULE-16 in spec/rules.md, AC-20/AC-24/AC-25).
final class DemoModeScreenTests: XCTestCase {

    @MainActor
    private func freshSession(clock: Clock) -> RideSession {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: clock, rideStore: rideStore)
        let engine = FeatureEngine(rideTracker: tracker, route: [], clock: clock)
        return RideSession(
            rideTracker: tracker, featureEngine: engine, clock: clock, routeId: "route-1",
            routeStore: RouteStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")),
            decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()),
            snapshotIntervalSeconds: 60, pollGranularitySeconds: 1.0)
    }

    @MainActor
    func testHomeViewShowsTheDemoModeEntryPointInDebug() {
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let homeView = HomeView(routeStore: routeStore, appRouter: AppRouter())

        XCTAssertTrue(homeView.showsDemoModeEntryPoint)
    }

    @MainActor
    func testSpeedDefaultsToOne() {
        let viewModel = DemoModeViewModel()

        XCTAssertEqual(viewModel.speed, 1)
    }

    @MainActor
    func testSetSpeedClampsWithinRange() {
        let viewModel = DemoModeViewModel()

        viewModel.setSpeed(10)

        XCTAssertEqual(viewModel.speed, 10)
    }

    @MainActor
    func testSetSpeedClampsBeyondTheUpperBound() {
        let viewModel = DemoModeViewModel()

        viewModel.setSpeed(100)

        XCTAssertEqual(viewModel.speed, 20)
    }

    @MainActor
    func testSetSpeedClampsBelowTheLowerBound() {
        let viewModel = DemoModeViewModel()

        viewModel.setSpeed(0)

        XCTAssertEqual(viewModel.speed, 1)
    }

    @MainActor
    func testStartInvokesTheCallbackWithTheCurrentSpeedAndReturnsItsSession() async {
        var startedAtSpeed: Double?
        let fakeSession = freshSession(clock: ReplayClock())
        let screen = DemoModeScreen(onStart: { speed in
            startedAtSpeed = speed
            return fakeSession
        })

        let returned = await screen.onStart(5)

        XCTAssertEqual(startedAtSpeed, 5)
        XCTAssertNotNil(returned)
    }

    // MARK: - Force check (task-4.4, AC-24)

    @MainActor
    func testForceNextCheckOnTheViewModelForcesTheActiveSessionsNextStep() async throws {
        let clock = ReplayClock()
        let session = freshSession(clock: clock)
        let viewModel = DemoModeViewModel()
        viewModel.setActiveSession(session)

        await viewModel.forceNextCheck()
        let ran = try await session.step()

        XCTAssertTrue(ran, "forceNextCheck() must make the next step() run immediately, without waiting out the cadence")
    }

    @MainActor
    func testForceNextCheckWithNoActiveSessionIsANoOp() async {
        let viewModel = DemoModeViewModel()

        await viewModel.forceNextCheck() // must not crash
    }
}

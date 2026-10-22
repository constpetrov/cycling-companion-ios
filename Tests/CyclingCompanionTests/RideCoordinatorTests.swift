import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Ride lifecycle locks and cancellation (RULE-1/RULE-2/RULE-3 in milestone 7's rules.md,
/// AC-3 to AC-8). Ported from `AppRouterTests` and `RideFinisherTests` without weakening any
/// assertion: the behaviours came from field-test bugs (f1aa828, PR #1).
final class RideCoordinatorTests: XCTestCase {

    @MainActor
    private func liveRide() -> LiveRide {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let tracker = RideTracker(
            rideId: UUID().uuidString, routeId: "route-1", startTime: Date(), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
        let log = DecisionLog()
        let session = RideSession(
            rideTracker: tracker, featureEngine: FeatureEngine(rideTracker: tracker, route: [], clock: ReplayClock()),
            clock: ReplayClock(), routeId: "route-1",
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            decisionLog: log, notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log))
        return LiveRide(
            tracker: tracker, session: session,
            trackingTask: Task { try? await Task.sleep(nanoseconds: .max) },
            sessionTask: Task { try? await Task.sleep(nanoseconds: .max) })
    }

    // MARK: - Ported from AppRouterTests

    @MainActor
    func testReplacingLiveRideCancelsBothOldTasks() {
        let coordinator = RideCoordinator()
        let first = liveRide()
        let second = liveRide()
        coordinator.activate(first)

        coordinator.activate(second)

        XCTAssertTrue(first.trackingTask.isCancelled)
        XCTAssertTrue(first.sessionTask.isCancelled)
        XCTAssertFalse(second.sessionTask.isCancelled)
        coordinator.end(second)
        XCTAssertTrue(second.trackingTask.isCancelled)
        XCTAssertTrue(second.sessionTask.isCancelled)
    }

    /// Was `testPlaceholderCannotDiscardAnActiveRide`: the `.liveRide(nil)` placeholder no longer
    /// exists; its job was to let a launch-time resume run. The equivalent guarantee is that a
    /// resume attempt can never displace a ride that is already active.
    @MainActor
    func testResumeCannotDiscardAnActiveRide() {
        let coordinator = RideCoordinator()
        let ride = liveRide()
        coordinator.activate(ride)

        XCTAssertFalse(coordinator.beginPreparingRide(resuming: true))

        XCTAssertTrue(coordinator.activeRide?.tracker === ride.tracker)
        XCTAssertFalse(ride.sessionTask.isCancelled)
        XCTAssertFalse(ride.trackingTask.isCancelled)
        coordinator.end(ride)
    }

    @MainActor
    func testReactivatingTheSameTrackerDoesNotCancelIt() {
        let coordinator = RideCoordinator()
        let ride = liveRide()
        coordinator.activate(ride)

        coordinator.activate(ride)

        XCTAssertFalse(ride.trackingTask.isCancelled)
        XCTAssertFalse(ride.sessionTask.isCancelled)
        coordinator.end(ride)
    }

    // MARK: - Start/resume lock (AC-3, AC-4)

    @MainActor
    func testSecondPrepareIsRejectedUntilTheFirstEnds() {
        let coordinator = RideCoordinator()

        XCTAssertTrue(coordinator.beginPreparingRide())
        XCTAssertFalse(coordinator.beginPreparingRide())
        XCTAssertFalse(coordinator.beginPreparingRide(resuming: true))
        coordinator.endPreparingRide()

        XCTAssertTrue(coordinator.beginPreparingRide())
    }

    @MainActor
    func testStartIsRejectedWhileARideIsActive() {
        let coordinator = RideCoordinator()
        let ride = liveRide()
        coordinator.activate(ride)

        XCTAssertFalse(coordinator.beginPreparingRide())
        XCTAssertTrue(coordinator.activeRide?.tracker === ride.tracker)
        coordinator.end(ride)
    }

    @MainActor
    func testPhaseFollowsPrepareActivateFinish() {
        let coordinator = RideCoordinator()
        XCTAssertEqual(coordinator.phase, .idle)

        _ = coordinator.beginPreparingRide(resuming: true)
        XCTAssertEqual(coordinator.phase, .resuming)
        let ride = liveRide()
        coordinator.activate(ride)
        coordinator.endPreparingRide()
        XCTAssertEqual(coordinator.phase, .active)

        _ = coordinator.beginFinishingRide()
        XCTAssertEqual(coordinator.phase, .finishing)
        coordinator.end(ride)
        coordinator.endFinishingRide()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: - Finish lock (AC-5), ported from RideFinisherTests

    @MainActor
    func testFinishCanRunAgainAfterAPreviousFinishCompleted() {
        let coordinator = RideCoordinator()
        XCTAssertTrue(coordinator.beginFinishingRide())
        XCTAssertFalse(coordinator.beginFinishingRide())
        coordinator.endFinishingRide()
        XCTAssertTrue(coordinator.beginFinishingRide())
    }

    // MARK: - Cancellation only through end/replace (AC-6, AC-7, AC-8)

    @MainActor
    func testEndingARideCancelsBothTasksAndClearsIt() {
        let coordinator = RideCoordinator()
        let ride = liveRide()
        coordinator.activate(ride)

        coordinator.end(ride)

        XCTAssertTrue(ride.trackingTask.isCancelled)
        XCTAssertTrue(ride.sessionTask.isCancelled)
        XCTAssertNil(coordinator.activeRide)
    }

    // MARK: - Presentation (RULE-1/RULE-7)

    @MainActor
    func testCoverShowsLiveThenSummaryUntilDone() {
        let coordinator = RideCoordinator()
        XCTAssertNil(coordinator.presentation)
        let ride = liveRide()

        coordinator.activate(ride)
        guard case .live = coordinator.presentation else { return XCTFail("expected .live") }

        coordinator.end(ride)
        guard case .live = coordinator.presentation else { return XCTFail("cover stays until the outcome is known") }
        coordinator.presentSummary(.notSaved)
        guard case .summary = coordinator.presentation else { return XCTFail("expected .summary") }

        coordinator.dismissSummary()
        XCTAssertNil(coordinator.presentation)
    }

    @MainActor
    func testDismissSummaryDoesNothingWhileLive() {
        let coordinator = RideCoordinator()
        let ride = liveRide()
        coordinator.activate(ride)

        coordinator.dismissSummary()

        guard case .live = coordinator.presentation else { return XCTFail("expected .live") }
        coordinator.end(ride)
    }
}

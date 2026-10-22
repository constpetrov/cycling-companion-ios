import RoutePersistence
import XCTest

@testable import CyclingCompanion

@MainActor
private final class RecordingIdleTimer: IdleTimerControlling {
    private(set) var calls: [Bool] = []
    var isDisabled: Bool { calls.last ?? false }

    nonisolated init() {}

    func setIdleTimerDisabled(_ disabled: Bool) {
        calls.append(disabled)
    }
}

/// task-2.5 (RULE-13): AC-34 to AC-38.
final class KeepScreenOnTests: XCTestCase {

    @MainActor
    private func viewModel(preference: KeepScreenOnPreference, idleTimer: IdleTimerControlling) -> LiveRideViewModel {
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(), route: [],
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(),
            rideStore: RideStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        return LiveRideViewModel(
            tracker: tracker, clock: ReplayClock(), keepScreenOnPreference: preference, idleTimer: idleTimer)
    }

    /// AC-37: first use after install — the stored preference is absent, so it reads off.
    @MainActor
    func testDefaultsToOffOnAFreshInstall() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let viewModel = viewModel(
            preference: UserDefaultsKeepScreenOnPreference(defaults: defaults), idleTimer: RecordingIdleTimer())

        XCTAssertFalse(viewModel.keepScreenOn)
    }

    /// AC-34: on + dashboard visible → auto-lock off.
    @MainActor
    func testOnAndVisibleDisablesAutoLock() {
        let idleTimer = RecordingIdleTimer()
        let viewModel = viewModel(preference: InMemoryKeepScreenOnPreference(), idleTimer: idleTimer)
        viewModel.dashboardDidAppear()

        viewModel.setKeepScreenOn(true)

        XCTAssertTrue(idleTimer.isDisabled)
    }

    /// AC-35: off → auto-lock stays normal even while the dashboard is visible.
    @MainActor
    func testOffLeavesAutoLockAlone() {
        let idleTimer = RecordingIdleTimer()
        let viewModel = viewModel(preference: InMemoryKeepScreenOnPreference(), idleTimer: idleTimer)

        viewModel.dashboardDidAppear()

        XCTAssertFalse(idleTimer.isDisabled)
        XCTAssertFalse(idleTimer.calls.contains(true))
    }

    /// AC-36: leaving the dashboard (including when the ride ends) restores auto-lock.
    @MainActor
    func testLeavingTheDashboardRestoresAutoLock() {
        let idleTimer = RecordingIdleTimer()
        let viewModel = viewModel(preference: InMemoryKeepScreenOnPreference(isEnabled: true), idleTimer: idleTimer)
        viewModel.dashboardDidAppear()
        XCTAssertTrue(idleTimer.isDisabled)

        viewModel.dashboardDidDisappear()

        XCTAssertFalse(idleTimer.isDisabled)
    }

    /// AC-38: the choice carries over to the next ride, including after an app restart.
    @MainActor
    func testTheChoiceIsRememberedForTheNextRide() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = viewModel(
            preference: UserDefaultsKeepScreenOnPreference(defaults: defaults), idleTimer: RecordingIdleTimer())
        first.setKeepScreenOn(true)

        let nextRide = viewModel(
            preference: UserDefaultsKeepScreenOnPreference(defaults: defaults), idleTimer: RecordingIdleTimer())

        XCTAssertTrue(nextRide.keepScreenOn)
    }
}

import XCTest

@testable import CyclingCompanion

@MainActor
private final class FakePermissions: PermissionStatusProviding {
    var snapshot: PermissionSnapshot
    private(set) var calls: [String] = []

    init(_ snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func current() async -> PermissionSnapshot { snapshot }

    func requestLocationWhenInUse() async {
        calls.append("whenInUse")
        snapshot.location = .whenInUse
    }

    func requestLocationAlways() async {
        calls.append("always")
        snapshot.location = .always
    }

    func requestNotifications() async {
        calls.append("notifications")
        snapshot.notifications = .authorized
    }

    func openSettings() {
        calls.append("settings")
    }
}

/// task-6.1 (RULE-21): AC-86 to AC-93.
final class ReadinessTests: XCTestCase {

    private func snapshot(
        _ location: LocationPermission, precise: Bool = true, _ notifications: NotificationPermission
    ) -> PermissionSnapshot {
        PermissionSnapshot(location: location, preciseLocation: precise, notifications: notifications)
    }

    /// AC-86.
    func testEverythingInPlaceNeedsNoCheck() {
        let decision = ReadinessDecision.evaluate(snapshot(.always, .authorized))

        XCTAssertFalse(decision.needsCheck)
        XCTAssertTrue(decision.canStart)
        XCTAssertTrue(decision.items.isEmpty)
    }

    /// AC-87 over every combination: the check shows exactly when something is missing.
    func testTheCheckShowsWhenAnythingIsMissing() {
        let locations: [LocationPermission] = [.notDetermined, .denied, .whenInUse, .always]
        let notifications: [NotificationPermission] = [.notDetermined, .denied, .authorized]
        for location in locations {
            for precise in [true, false] {
                for notification in notifications {
                    let decision = ReadinessDecision.evaluate(snapshot(location, precise: precise, notification))
                    let allGood = location == .always && precise && notification == .authorized
                    XCTAssertEqual(decision.needsCheck, !allGood, "\(location) precise=\(precise) \(notification)")
                }
            }
        }
    }

    /// AC-88/AC-89: Grant where iOS can still prompt, Settings where it can't.
    func testGrantForPromptableAndSettingsForDenied() {
        let undecided = ReadinessDecision.evaluate(snapshot(.notDetermined, .notDetermined))
        XCTAssertEqual(undecided.items.map(\.action), [.grant, .grant])

        let denied = ReadinessDecision.evaluate(snapshot(.denied, .denied))
        XCTAssertEqual(denied.items.map(\.action), [.openSettings, .openSettings])
    }

    /// AC-90: no location → can't start.
    func testNoLocationBlocksTheStart() {
        XCTAssertFalse(ReadinessDecision.evaluate(snapshot(.notDetermined, .authorized)).canStart)
        XCTAssertFalse(ReadinessDecision.evaluate(snapshot(.denied, .authorized)).canStart)
    }

    /// AC-91: When In Use can start, with a warning.
    func testWhenInUseCanStartWithAWarning() {
        let decision = ReadinessDecision.evaluate(snapshot(.whenInUse, .authorized))

        XCTAssertTrue(decision.canStart)
        XCTAssertTrue(decision.warnsTrackingStopsWhenLocked)
        XCTAssertTrue(decision.needsCheck)
    }

    /// AC-92.
    func testMissingNotificationsOfferStartingWithoutSuggestions() {
        XCTAssertTrue(ReadinessDecision.evaluate(snapshot(.always, .denied)).offersStartWithoutSuggestions)
        XCTAssertTrue(ReadinessDecision.evaluate(snapshot(.whenInUse, .notDetermined)).offersStartWithoutSuggestions)
        XCTAssertFalse(ReadinessDecision.evaluate(snapshot(.denied, .denied)).offersStartWithoutSuggestions)
        XCTAssertFalse(ReadinessDecision.evaluate(snapshot(.always, .authorized)).offersStartWithoutSuggestions)
    }

    func testImpreciseLocationSendsToSettings() {
        let decision = ReadinessDecision.evaluate(snapshot(.always, precise: false, .authorized))

        XCTAssertEqual(decision.items.map(\.kind), [.preciseLocation])
        XCTAssertEqual(decision.items.first?.action, .openSettings)
    }

    /// Grant asks for When In Use first, then Always (iOS's two-step flow), and refreshes (AC-93).
    @MainActor
    func testLocationIsRequestedWhenInUseFirstThenAlways() async {
        let permissions = FakePermissions(snapshot(.notDetermined, .authorized))
        let viewModel = ReadinessViewModel(permissions: permissions)
        await viewModel.refresh()

        await viewModel.perform(viewModel.decision!.items.first!)
        XCTAssertEqual(permissions.calls, ["whenInUse"])
        XCTAssertTrue(viewModel.decision!.warnsTrackingStopsWhenLocked)

        await viewModel.perform(viewModel.decision!.items.first!)
        XCTAssertEqual(permissions.calls, ["whenInUse", "always"])
        XCTAssertFalse(viewModel.decision!.needsCheck)
    }

    /// AC-93: a change made elsewhere (Settings) shows up on refresh.
    @MainActor
    func testRefreshPicksUpAChangeMadeInSettings() async {
        let permissions = FakePermissions(snapshot(.denied, .authorized))
        let viewModel = ReadinessViewModel(permissions: permissions)
        await viewModel.refresh()
        XCTAssertFalse(viewModel.decision!.canStart)

        permissions.snapshot.location = .always
        await viewModel.refresh()

        XCTAssertTrue(viewModel.decision!.canStart)
        XCTAssertFalse(viewModel.decision!.needsCheck)
    }

    @MainActor
    func testDeniedItemsOpenSettings() async {
        let permissions = FakePermissions(snapshot(.denied, .authorized))
        let viewModel = ReadinessViewModel(permissions: permissions)
        await viewModel.refresh()

        await viewModel.perform(viewModel.decision!.items.first!)

        XCTAssertEqual(permissions.calls, ["settings"])
    }
}

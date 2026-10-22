import XCTest

@testable import CyclingCompanion

@MainActor
private final class SettablePermissions: PermissionStatusProviding {
    var snapshot: PermissionSnapshot

    init(_ snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func current() async -> PermissionSnapshot { snapshot }
    func requestLocationWhenInUse() async {}
    func requestLocationAlways() async {}
    func requestNotifications() async {}
    func openSettings() {}
}

/// task-6.2 (RULE-8/RULE-21): Start Ride goes through the readiness check (AC-86, AC-87, AC-90 to
/// AC-92); Demo rides don't (AC-94).
final class RideStartFlowTests: XCTestCase {

    @MainActor
    private func flow(_ snapshot: PermissionSnapshot) -> (RideStartFlow, SettablePermissions, () -> Int) {
        let permissions = SettablePermissions(snapshot)
        var starts = 0
        let flow = RideStartFlow(readiness: ReadinessViewModel(permissions: permissions), start: { starts += 1 })
        return (flow, permissions, { starts })
    }

    @MainActor
    func testEverythingInPlaceStartsWithoutTheSheet() async {
        let (flow, _, starts) = flow(PermissionSnapshot(location: .always, preciseLocation: true, notifications: .authorized))

        await flow.requestStart()

        XCTAssertEqual(starts(), 1)
        XCTAssertFalse(flow.isReadinessSheetPresented)
    }

    @MainActor
    func testSomethingMissingOpensTheSheetInsteadOfStarting() async {
        let (flow, _, starts) = flow(PermissionSnapshot(location: .whenInUse, preciseLocation: true, notifications: .authorized))

        await flow.requestStart()

        XCTAssertEqual(starts(), 0)
        XCTAssertTrue(flow.isReadinessSheetPresented)
    }

    @MainActor
    func testTheSheetStartsOnceLocationAllowsIt() async {
        let (flow, _, starts) = flow(PermissionSnapshot(location: .whenInUse, preciseLocation: true, notifications: .denied))
        await flow.requestStart()

        await flow.startFromSheet()  // "Start without suggestions"

        XCTAssertEqual(starts(), 1)
        XCTAssertFalse(flow.isReadinessSheetPresented)
    }

    @MainActor
    func testTheSheetWontStartWithoutLocation() async {
        let (flow, permissions, starts) = flow(
            PermissionSnapshot(location: .denied, preciseLocation: true, notifications: .authorized))
        await flow.requestStart()

        await flow.startFromSheet()
        XCTAssertEqual(starts(), 0)
        XCTAssertTrue(flow.isReadinessSheetPresented)

        permissions.snapshot.location = .always  // turned on in Settings
        await flow.startFromSheet()
        XCTAssertEqual(starts(), 1)
    }

    /// AC-94: Demo rides start through `AppDependencies.startDemoRide`, never the readiness check.
    @MainActor
    func testDemoRidesBypassTheReadinessCheck() async throws {
        let dependencies = AppDependencies.preview
        try await dependencies.routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 1_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInputFixture.point(0), PersistedPointInputFixture.point(1_000),
            ], pois: [], status: "ready")
        dependencies.pointer.routeId = "route-1"

        let session = await dependencies.startDemoRide(speed: 20)

        XCTAssertNotNil(session)
        XCTAssertFalse(dependencies.rideStartFlow.isReadinessSheetPresented)
        XCTAssertNil(dependencies.rideStartFlow.readiness.decision, "the check never ran")
        if let ride = dependencies.rideCoordinator.activeRide { dependencies.rideCoordinator.end(ride) }
    }
}

import RoutePersistence

private enum PersistedPointInputFixture {
    static func point(_ meters: Double) -> PersistedPointInput {
        PersistedPointInput(
            latitude: 52 + meters / 111_195, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: meters)
    }
}

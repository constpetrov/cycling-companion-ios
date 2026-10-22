import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-6.7 (RULE-27): AC-120, AC-121.
final class OrphanedRideTests: XCTestCase {

    private func freshFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    /// AC-120 → AC-121 end to end through the launch-time resume.
    @MainActor
    func testAnOrphanedRideIsReportedAndDiscardedForGood() async throws {
        let rideStore = RideStore(fileURL: freshFile())
        let routeStore = RouteStore(fileURL: freshFile())  // no route "gone"
        try await rideStore.persist(
            PersistedRide(
                id: "ride-1", routeId: "gone", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 100, totalMovingTimeSeconds: 20, track: []))
        let home = HomeViewModel(
            routeStore: routeStore, pointer: CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            rideStore: rideStore)
        let log = DecisionLog()
        func resumer() -> RideResumer {
            RideResumer(
                rideStore: rideStore, routeStore: routeStore, rideCoordinator: RideCoordinator(), decisionLog: log,
                notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log),
                onOrphanedRide: { home.reportOrphanedRide(id: $0) })
        }

        await resumer().resumeIfNeeded()
        XCTAssertEqual(home.orphanedRideId, "ride-1")

        await home.discardOrphanedRide()
        XCTAssertNil(home.orphanedRideId)
        let remaining = try await rideStore.fetch(rideId: "ride-1")
        XCTAssertNil(remaining, "the unfinished ride is deleted")

        await resumer().resumeIfNeeded()  // the next launch
        XCTAssertNil(home.orphanedRideId, "no notice on later launches")
    }

    @MainActor
    func testAResumableRideIsNotReportedAsOrphaned() async throws {
        let rideStore = RideStore(fileURL: freshFile())
        let routeStore = RouteStore(fileURL: freshFile())
        try await routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 1_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52.009, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ], pois: [], status: "ready")
        try await rideStore.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 100, totalMovingTimeSeconds: 20, track: []))
        var reported: [String] = []
        let coordinator = RideCoordinator()
        let log = DecisionLog()
        let resumer = RideResumer(
            rideStore: rideStore, routeStore: routeStore, rideCoordinator: coordinator, decisionLog: log,
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log),
            onOrphanedRide: { reported.append($0) })

        await resumer.resumeIfNeeded()

        XCTAssertTrue(reported.isEmpty)
        XCTAssertNotNil(coordinator.activeRide)
        if let ride = coordinator.activeRide { coordinator.end(ride) }
    }

    func testDeletingAnUnknownRideIsHarmless() async throws {
        let store = RideStore(fileURL: freshFile())

        try await store.delete(rideId: "nope")

        let all = try await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }
}

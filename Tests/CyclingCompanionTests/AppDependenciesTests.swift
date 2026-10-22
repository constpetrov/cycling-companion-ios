import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// AC-9/AC-10 (RULE-5/RULE-6 in milestone 7's rules.md).
final class AppDependenciesTests: XCTestCase {

    /// AC-9: the ride starter, finisher, resumer and Home all share one graph — the same
    /// coordinator and the same stores — rather than each building their own.
    @MainActor
    func testRideComponentsShareOneCoordinatorAndRideStore() async throws {
        let dependencies = AppDependencies.preview
        try await dependencies.routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 1_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ], pois: [], status: "ready")
        dependencies.pointer.routeId = "route-1"

        await dependencies.rideStarter.startRide()

        let ride = try XCTUnwrap(dependencies.rideCoordinator.activeRide, "the shared coordinator sees the started ride")
        await dependencies.rideFinisher.finishRide(ride)
        let stored = try await dependencies.rideStore.fetch(rideId: ride.tracker.rideId)
        XCTAssertNotNil(stored?.endTime, "the finisher writes to the same RideStore the ride was tracked in")
    }

    /// AC-10: the preview graph never reaches a network — every request fails as offline.
    @MainActor
    func testPreviewGraphIsOffline() async {
        let dependencies = AppDependencies.preview

        do {
            _ = try await dependencies.authClient.signIn(placeholderIdentity: "preview")
            XCTFail("the preview transport must not succeed")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    /// AC-10: each preview graph starts empty, isolated from the app's real data.
    @MainActor
    func testPreviewGraphStartsEmpty() async throws {
        let dependencies = AppDependencies.preview

        XCTAssertNil(dependencies.pointer.routeId)
        let rides = try await dependencies.rideStore.fetchAll()
        XCTAssertTrue(rides.isEmpty)
    }
}

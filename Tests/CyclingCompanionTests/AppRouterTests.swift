import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.1 validation (RULE-9/RULE-16 in spec/rules.md, AC-1).
final class AppRouterTests: XCTestCase {

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    func testStartsOnHomeBeforeDeterminingTheInitialScreen() {
        let router = AppRouter()

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testNoUnfinishedRideSettlesOnHome() async throws {
        let store = freshRideStore()
        let router = AppRouter()

        await router.determineInitialScreen(rideStore: store)

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testAnUnfinishedRideSettlesOnTheLiveRideScreen() async throws {
        let store = freshRideStore()
        try await store.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 1_000, totalMovingTimeSeconds: 60, track: []))
        let router = AppRouter()

        await router.determineInitialScreen(rideStore: store)

        XCTAssertEqual(router.currentScreen, .liveRide(nil))
    }

    @MainActor
    func testAFinishedRideDoesNotCountAsUnfinished() async throws {
        let store = freshRideStore()
        try await store.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
                endTime: Date(timeIntervalSince1970: 100), totalDistanceMeters: 1_000, totalMovingTimeSeconds: 60,
                track: []))
        let router = AppRouter()

        await router.determineInitialScreen(rideStore: store)

        XCTAssertEqual(router.currentScreen, .home)
    }

    @MainActor
    func testShowMutatesCurrentScreen() {
        let router = AppRouter()

        router.show(.liveRide(nil))

        XCTAssertEqual(router.currentScreen, .liveRide(nil))
    }
}

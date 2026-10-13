import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.6 validation (RULE-9/RULE-16 in spec/rules.md, AC-10/AC-11): Start Ride navigates to
/// the live ride screen regardless of whether corridor POIs have finished building.
final class RideStarterTests: XCTestCase {

    private func freshRouteStore() -> RouteStore {
        RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    private func freshPointer(routeId: String?) -> CurrentRoutePointer {
        var pointer = CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        pointer.routeId = routeId
        return pointer
    }

    private func samplePoints() -> [PersistedPointInput] {
        [
            PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
            PersistedPointInput(latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
        ]
    }

    @MainActor
    private func makeStarter(routeStore: RouteStore, pointer: CurrentRoutePointer, appRouter: AppRouter) -> RideStarter {
        RideStarter(
            routeStore: routeStore, pointer: pointer, appRouter: appRouter, decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()))
    }

    @MainActor
    func testStartRideNavigatesToTheLiveRideScreenBeforeCorridorSettles() async throws {
        let routeStore = freshRouteStore()
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil,
            points: samplePoints(), pois: [], status: "building")
        let pointer = freshPointer(routeId: "route-1")
        let appRouter = AppRouter()
        let starter = makeStarter(routeStore: routeStore, pointer: pointer, appRouter: appRouter)

        await starter.startRide()

        guard case .liveRide(let liveRide) = appRouter.currentScreen else {
            XCTFail("expected the live ride screen")
            return
        }
        XCTAssertNotNil(liveRide?.tracker)
        liveRide?.trackingTask.cancel()
        liveRide?.sessionTask.cancel()
    }

    @MainActor
    func testStartRideNavigatesToTheLiveRideScreenAfterCorridorSettles() async throws {
        let routeStore = freshRouteStore()
        let pois = [
            PersistedPoiInput(
                osmId: 1, type: "WATER", name: nil, latitude: 52.0005, longitude: 13.0, kmMarkMeters: 500,
                detourMeters: 20, openingHours: nil)
        ]
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil,
            points: samplePoints(), pois: pois, status: "ready")
        let pointer = freshPointer(routeId: "route-1")
        let appRouter = AppRouter()
        let starter = makeStarter(routeStore: routeStore, pointer: pointer, appRouter: appRouter)

        await starter.startRide()

        guard case .liveRide(let liveRide) = appRouter.currentScreen else {
            XCTFail("expected the live ride screen")
            return
        }
        XCTAssertNotNil(liveRide?.tracker)
        liveRide?.trackingTask.cancel()
        liveRide?.sessionTask.cancel()
    }

    @MainActor
    func testStartRideIsANoOpWithNoCurrentRoute() async {
        let routeStore = freshRouteStore()
        let pointer = freshPointer(routeId: nil)
        let appRouter = AppRouter()
        let starter = makeStarter(routeStore: routeStore, pointer: pointer, appRouter: appRouter)

        await starter.startRide()

        XCTAssertEqual(appRouter.currentScreen, .home)
    }
}

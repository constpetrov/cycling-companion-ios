import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Milestone 8 review: the maps draw only the 2 nearest stops of each type ahead along the route.
final class MapStopSelectionTests: XCTestCase {

    private func stop(_ id: Int64, _ type: String, km: Double) -> PersistedPoiInput {
        PersistedPoiInput(osmId: id, type: type, name: nil, latitude: 52, longitude: 13, kmMarkMeters: km, detourMeters: 0,
                          openingHours: nil)
    }

    private lazy var stops = [
        stop(1, "CAFE", km: 100), stop(2, "CAFE", km: 900), stop(3, "CAFE", km: 400), stop(4, "CAFE", km: 600),
        stop(5, "WATER", km: 450), stop(6, "WATER", km: 50), stop(7, "TOILETS", km: 2_000),
    ]

    func testTwoNearestOfEachTypeAheadInRouteOrder() {
        let chosen = MapStopSelection.nearestAhead(stops, from: 300)

        XCTAssertEqual(chosen.map(\.osmId), [3, 5, 4, 7], "cafés 400 and 600, water 450, toilets 2000; nothing behind")
    }

    func testFromTheStartOfTheRoute() {
        XCTAssertEqual(MapStopSelection.nearestAhead(stops, from: 0).map(\.osmId), [6, 1, 3, 5, 7])
    }

    func testTheHighlightedStopIsAlwaysShownEvenIfItWouldNotBeChosen() {
        let chosen = MapStopSelection.nearestAhead(stops, from: 300, alwaysInclude: 2)

        XCTAssertEqual(chosen.map(\.osmId), [3, 5, 4, 2, 7])
        XCTAssertEqual(MapStopSelection.nearestAhead(stops, from: 300, alwaysInclude: 3).map(\.osmId), [3, 5, 4, 7], "no duplicate")
    }

    func testThousandsOfStopsBecomeAHandful() {
        let dense = (0..<3_000).map { stop(Int64($0), ["CAFE", "WATER", "TOILETS", "FOOD_SHOP", "REST_SHELTER", "BIKE_REPAIR"][$0 % 6], km: Double($0) * 5) }

        XCTAssertEqual(MapStopSelection.nearestAhead(dense, from: 1_000).count, 12)
    }

    // MARK: - Live map

    @MainActor
    private func liveRideViewModel(stopTypeFilter: StopTypeFilter = .allEnabled) async throws
        -> (LiveRideViewModel, RouteStore)
    {
        let routeStore = RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 685, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 685),
            ],
            pois: [stop(1, "CAFE", km: 100), stop(3, "CAFE", km: 400), stop(4, "CAFE", km: 500), stop(8, "CAFE", km: 650),
                   stop(5, "WATER", km: 450)],
            status: "ready")
        let clock = ReplayClock()
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            route: [
                ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
                ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 685),
            ],
            locationSource: ReplayLocationSource(fixes: [
                LocationFix(latitude: 52.0, longitude: 13.005, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 0))
            ]),
            sensorSource: ReplaySensorSource(samples: []), clock: clock,
            rideStore: RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        await tracker.start()  // rider at about 342 m
        return (LiveRideViewModel(tracker: tracker, clock: clock, stopTypeFilter: stopTypeFilter), routeStore)
    }

    @MainActor
    func testTheLiveMapShowsTheNearestStopsAheadOfTheRider() async throws {
        let (viewModel, routeStore) = try await liveRideViewModel()

        await viewModel.loadRoute(from: routeStore)

        XCTAssertEqual(viewModel.visibleStops.map(\.osmId), [3, 5, 4], "the café behind and the third café ahead aren't drawn")
        XCTAssertEqual(viewModel.stops.count, 5, "every stop is still known")
        XCTAssertEqual(viewModel.routeCoordinates.count, 2)
    }

    @MainActor
    func testTheLiveMapLeavesOutStopTypesTurnedOffInSettings() async throws {
        let (viewModel, routeStore) = try await liveRideViewModel(stopTypeFilter: StopTypeFilter { ["WATER"] })

        await viewModel.loadRoute(from: routeStore)

        XCTAssertEqual(viewModel.visibleStops.map(\.osmId), [3, 4], "the water tap isn't drawn")
        XCTAssertEqual(viewModel.stops.count, 5, "it is still known, e.g. for a notification tap")
    }
}

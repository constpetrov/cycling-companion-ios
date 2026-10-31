import CoreLocation
import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.3 (RULE-9/RULE-10/RULE-12 in milestone 7's rules.md): AC-20 to AC-24 and AC-26 to AC-33.
final class LiveRideViewModelTests: XCTestCase {

    private let german = Locale(identifier: "de_DE")
    private let american = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private let metersPerDegreeLongitude = GeoMath.earthRadiusMeters * .pi / 180 * cos(52.0 * .pi / 180)

    /// 10 km due east from 52°N 13°E, with the endpoint placed so the geometry really is 10 km.
    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(
                latitude: 52.0, longitude: 13.0 + 10_000 / metersPerDegreeLongitude, elevationMeters: nil,
                cumulativeDistanceMeters: 10_000),
        ]
    }

    /// A fix `metersAlong` the route, `offRouteMeters` north of it, using GeoMath's projection.
    private func fix(metersAlong: Double, offRouteMeters: Double = 0, speed: Double = 5, time: TimeInterval) -> LocationFix {
        let latitude = 52.0 + (offRouteMeters / GeoMath.earthRadiusMeters) * 180 / .pi
        return LocationFix(
            latitude: latitude, longitude: 13.0 + metersAlong / metersPerDegreeLongitude,
            speedMetersPerSecond: speed, timestamp: Date(timeIntervalSince1970: time))
    }

    @MainActor
    private func tracker(fixes: [LocationFix], clock: Clock) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: route(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: clock,
            rideStore: RideStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    }

    // MARK: - Units (AC-23, AC-24)

    func testMetricLocaleUsesKilometresAndKilometresPerHour() {
        XCTAssertTrue(LiveRideViewModel.distanceText(meters: 12_300, locale: german).contains("km"))
        XCTAssertTrue(LiveRideViewModel.speedText(metersPerSecond: 5, locale: german).contains("km/h"))
        XCTAssertTrue(LiveRideViewModel.speedText(metersPerSecond: 5, locale: german).contains("18,0"), "5 m/s = 18 km/h")
    }

    func testUSLocaleUsesMilesAndMilesPerHour() {
        XCTAssertTrue(LiveRideViewModel.distanceText(meters: 12_300, locale: american).contains("mi"))
        XCTAssertTrue(LiveRideViewModel.speedText(metersPerSecond: 5, locale: american).contains("mph"))
        XCTAssertTrue(LiveRideViewModel.speedText(metersPerSecond: 5, locale: american).contains("11.2"), "5 m/s ≈ 11.2 mph")
    }

    // MARK: - Metrics (AC-20, AC-21, AC-22)

    @MainActor
    func testDistanceRemainingSpeedAndArrivalTime() async {
        let clock = ReplayClock(start: Date(timeIntervalSince1970: 36_000))  // 10:00 UTC
        let fixes = (0...6).map { fix(metersAlong: Double($0) * 50, time: Double($0) * 10) }
        let tracker = tracker(fixes: fixes, clock: clock)
        await tracker.start()
        let viewModel = LiveRideViewModel(tracker: tracker, clock: clock, locale: american, timeZone: utc)

        await viewModel.refreshGPSState()

        XCTAssertEqual(viewModel.distanceRemainingMeters, 9_700, accuracy: 1)
        XCTAssertTrue(viewModel.distanceRemainingText.contains("mi"))
        XCTAssertNotNil(viewModel.speedText)
        let eta = try? XCTUnwrap(tracker.etaSeconds)
        let expectedArrival = Date(timeIntervalSince1970: 36_000 + (eta ?? 0))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: american, timeZone: utc))
        XCTAssertEqual(viewModel.arrivalTimeText, expectedArrival)
        XCTAssertTrue(viewModel.arrivalTimeText?.contains("AM") ?? false, "a clock time of day, not a duration")
    }

    @MainActor
    func testNoSpeedAndNoArrivalBeforeTheFirstFix() async {
        let clock = ReplayClock()
        let viewModel = LiveRideViewModel(tracker: tracker(fixes: [], clock: clock), clock: clock, locale: american)

        await viewModel.refreshGPSState()

        XCTAssertNil(viewModel.speedText)
        XCTAssertNil(viewModel.arrivalTimeText)
    }

    // MARK: - Off route (AC-26, AC-27, AC-28, AC-29)

    func testOffRouteBoundaryIsStrictlyAboveFiftyMetres() {
        XCTAssertFalse(LiveRideViewModel.isOffRoute(offRouteMeters: 49))
        XCTAssertFalse(LiveRideViewModel.isOffRoute(offRouteMeters: 50), "exactly 50 m is still on route")
        XCTAssertTrue(LiveRideViewModel.isOffRoute(offRouteMeters: 51))
        XCTAssertFalse(LiveRideViewModel.isOffRoute(offRouteMeters: nil))
    }

    @MainActor
    func testOffRouteFixRaisesTheBadgeAndKeepsTheLastDistanceRemaining() async {
        let clock = ReplayClock()
        let tracker = tracker(
            fixes: [fix(metersAlong: 1_000, time: 10), fix(metersAlong: 1_500, offRouteMeters: 200, time: 20)],
            clock: clock)
        await tracker.start()
        let viewModel = LiveRideViewModel(tracker: tracker, clock: clock, locale: german)

        XCTAssertTrue(viewModel.isOffRoute)
        XCTAssertEqual(viewModel.distanceRemainingMeters, 9_000, accuracy: 1, "held at the last on-route value")
    }

    @MainActor
    func testOnRouteFixHasNoBadge() async {
        let clock = ReplayClock()
        let tracker = tracker(fixes: [fix(metersAlong: 1_000, offRouteMeters: 20, time: 10)], clock: clock)
        await tracker.start()

        XCTAssertFalse(LiveRideViewModel(tracker: tracker, clock: clock).isOffRoute)
    }

    // MARK: - No GPS (AC-30 to AC-33)

    @MainActor
    func testNoGPSBeforeTheFirstFix() async {
        let clock = ReplayClock()
        let viewModel = LiveRideViewModel(tracker: tracker(fixes: [], clock: clock), clock: clock)

        await viewModel.refreshGPSState()

        XCTAssertTrue(viewModel.isGPSLost)
    }

    @MainActor
    func testNoGPSBoundaryAtThirtySeconds() async throws {
        for (gap, expected) in [(29.0, false), (30.0, true), (31.0, true)] {
            let clock = ReplayClock()
            let tracker = tracker(fixes: [fix(metersAlong: 0, time: 0)], clock: clock)
            await tracker.start()
            let viewModel = LiveRideViewModel(tracker: tracker, clock: clock)

            try await clock.sleep(for: gap)
            await viewModel.refreshGPSState()

            XCTAssertEqual(viewModel.isGPSLost, expected, "\(gap) s since the last fix")
        }
    }

    @MainActor
    func testGPSBadgeClearsWhenAFixArrivesAgain() async throws {
        let clock = ReplayClock()
        let tracker = tracker(fixes: [fix(metersAlong: 0, time: 0)], clock: clock)
        await tracker.start()
        let viewModel = LiveRideViewModel(tracker: tracker, clock: clock)
        try await clock.sleep(for: 45)
        await viewModel.refreshGPSState()
        XCTAssertTrue(viewModel.isGPSLost)

        let resumed = self.tracker(fixes: [fix(metersAlong: 0, time: 0)], clock: clock)
        await resumed.start()  // a fix recorded at the clock's current time
        let afterFix = LiveRideViewModel(tracker: resumed, clock: clock)
        await afterFix.refreshGPSState()

        XCTAssertFalse(afterFix.isGPSLost)
    }

    @MainActor
    func testMonitorChecksOncePerSecondUntilCancelled() async throws {
        let clock = ReplayClock()
        let viewModel = LiveRideViewModel(tracker: tracker(fixes: [], clock: clock), clock: clock)

        let monitor = Task { await viewModel.monitorGPS() }
        try await Task.sleep(nanoseconds: 50_000_000)
        monitor.cancel()
        await monitor.value

        let sleeps = await clock.sleepCalls
        XCTAssertFalse(sleeps.isEmpty)
        XCTAssertTrue(sleeps.allSatisfy { $0 == 1 })
    }
}

/// task-2.4 (RULE-11): follow / pan / recenter state for the dashboard map (AC-16 to AC-19).
final class LiveRideMapStateTests: XCTestCase {

    @MainActor
    private func viewModel(fixes: [LocationFix], clock: ReplayClock) async -> LiveRideViewModel {
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            route: [
                ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
                ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 685),
            ],
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: clock,
            rideStore: RideStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        await tracker.start()
        return LiveRideViewModel(tracker: tracker, clock: clock)
    }

    private func fix(longitude: Double) -> LocationFix {
        LocationFix(latitude: 52.0, longitude: longitude, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 0))
    }

    @MainActor
    func testFollowsTheRiderFromTheRidesOwnFix() async {
        let viewModel = await viewModel(fixes: [fix(longitude: 13.005)], clock: ReplayClock())

        await viewModel.refreshGPSState()

        XCTAssertTrue(viewModel.isFollowingRider)
        XCTAssertEqual(viewModel.cameraCenter?.longitude, 13.005)
        XCTAssertEqual(viewModel.riderCoordinate?.longitude, 13.005)
    }

    @MainActor
    func testPanningStopsFollowing() async {
        let viewModel = await viewModel(fixes: [fix(longitude: 13.005)], clock: ReplayClock())
        await viewModel.refreshGPSState()

        viewModel.riderDidPan()

        XCTAssertFalse(viewModel.isFollowingRider)
    }

    @MainActor
    func testCameraStaysPutWhilePannedEvenAsTheRiderMoves() async {
        let clock = ReplayClock()
        let viewModel = await viewModel(fixes: [fix(longitude: 13.002)], clock: clock)
        await viewModel.refreshGPSState()
        viewModel.riderDidPan()
        let before = viewModel.cameraCenter

        await viewModel.refreshGPSState()

        XCTAssertEqual(viewModel.cameraCenter?.longitude, before?.longitude)
    }

    @MainActor
    func testRecenterResumesFollowingAtTheRider() async {
        let viewModel = await viewModel(fixes: [fix(longitude: 13.007)], clock: ReplayClock())
        viewModel.riderDidPan()

        viewModel.recenter()

        XCTAssertTrue(viewModel.isFollowingRider)
        XCTAssertEqual(viewModel.cameraCenter?.longitude, 13.007)
    }

    @MainActor
    func testASmallMoveDoesNotReachTheMapThresholds() {
        let start = CLLocationCoordinate2D(latitude: 52.0, longitude: 13.0)
        let thirtyMetersNorth = CLLocationCoordinate2D(latitude: 52.00027, longitude: 13.0)

        XCTAssertFalse(
            LiveRideViewModel.hasMoved(
                from: start, to: thirtyMetersNorth, atLeast: LiveRideViewModel.cameraFollowStepMeters))
        XCTAssertTrue(
            LiveRideViewModel.hasMoved(
                from: start, to: thirtyMetersNorth, atLeast: LiveRideViewModel.riderMarkerStepMeters))
    }

    @MainActor
    func testAFirstPositionAlwaysCountsAsMoved() {
        let start = CLLocationCoordinate2D(latitude: 52.0, longitude: 13.0)

        XCTAssertTrue(LiveRideViewModel.hasMoved(from: nil, to: start, atLeast: LiveRideViewModel.cameraFollowStepMeters))
    }

    @MainActor
    func testTheMapDrawsTheRiderAfterTheFirstCheck() async {
        let viewModel = await viewModel(fixes: [fix(longitude: 13.005)], clock: ReplayClock())
        XCTAssertNil(viewModel.mapRiderCoordinate)

        await viewModel.refreshGPSState()

        XCTAssertEqual(viewModel.mapRiderCoordinate?.longitude, 13.005)
    }

    @MainActor
    func testLoadsTheRoutesLineAndStopsForTheMap() async throws {
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await routeStore.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 685, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 685),
            ],
            pois: [
                PersistedPoiInput(
                    osmId: 7, type: "CAFE", name: "Kaffee", latitude: 52.001, longitude: 13.005, kmMarkMeters: 340,
                    detourMeters: 110, openingHours: nil)
            ], status: "ready")
        let viewModel = await viewModel(fixes: [], clock: ReplayClock())

        await viewModel.loadRoute(from: routeStore)

        XCTAssertEqual(viewModel.routeCoordinates.count, 2)
        XCTAssertEqual(viewModel.stops.map(\.osmId), [7])
    }
}

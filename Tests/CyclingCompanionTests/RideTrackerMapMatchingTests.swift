import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.2 validation: the 50 m corridor gate (AC-2/AC-3/AC-4/AC-6), matching the same
/// within/at/beyond/resume pattern as `GeoMathClosestPointTests`, but driven through
/// `RideTracker` itself so the gating logic (not just the underlying geometry) is covered.
final class RideTrackerMapMatchingTests: XCTestCase {

    private let segmentEnd = 1_000.0

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: segmentEnd),
        ]
    }

    /// A fix at a given fraction along the route's longitude span, offset due north by
    /// `offRouteMeters` — the same equirectangular approximation `GeoMath.closestPointOnRoute`
    /// itself uses, so the off-route distance the test asserts against matches what the
    /// implementation actually computes.
    private func fix(fractionAlongRoute: Double, offRouteMeters: Double, time: TimeInterval) -> LocationFix {
        let longitude = 13.0 + fractionAlongRoute * 0.01
        let dLatRadians = offRouteMeters / GeoMath.earthRadiusMeters
        let latitude = 52.0 + dLatRadians * 180 / .pi
        return LocationFix(
            latitude: latitude, longitude: longitude, speedMetersPerSecond: 5,
            timestamp: Date(timeIntervalSince1970: time))
    }

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func tracker(fixes: [LocationFix], customRoute: [ResampledPoint]? = nil) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: customRoute ?? route(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: freshRideStore())
    }

    private func loopRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ResampledPoint(latitude: 52.01, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: 2_000),
            ResampledPoint(latitude: 52.01, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 3_000),
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 4_000),
        ]
    }

    @MainActor
    func testReturningToSharedStartFinishDoesNotResetProgress() async {
        let tracker = tracker(fixes: [
            LocationFix(latitude: 52.0002, longitude: 13.0, speedMetersPerSecond: 3,
                        timestamp: Date(timeIntervalSince1970: 0)),
            LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 0,
                        timestamp: Date(timeIntervalSince1970: 10)),
        ], customRoute: loopRoute())

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 4_000, accuracy: 1)
        let engine = FeatureEngine(rideTracker: tracker, route: loopRoute(), clock: ReplayClock())
        let snapshot = await engine.computeAndAppendSnapshot()
        XCTAssertEqual(snapshot.remainingEffortMeters ?? -1, 0, accuracy: 1)
    }

    @MainActor
    func testGpsNoiseNearStartCannotJumpToFinishOfLoop() async {
        let tracker = tracker(fixes: [
            LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 0,
                        timestamp: Date(timeIntervalSince1970: 0)),
            LocationFix(latitude: 52.00001, longitude: 13.0, speedMetersPerSecond: 0,
                        timestamp: Date(timeIntervalSince1970: 1)),
        ], customRoute: loopRoute())

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 0, accuracy: 1)
    }

    @MainActor
    func testResumedRideKeepsFinishBranchOfLoop() async throws {
        let store = freshRideStore()
        try await store.persist(PersistedRide(
            id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
            totalDistanceMeters: 3_980, totalMovingTimeSeconds: 600,
            track: [PersistedRideSample(
                latitude: 52.0002, longitude: 13.0, speedMetersPerSecond: 3, heartRateBPM: nil,
                cadenceRPM: nil, timestamp: Date(timeIntervalSince1970: 600))]))
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: loopRoute(),
            locationSource: ReplayLocationSource(fixes: [
                LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 0,
                            timestamp: Date(timeIntervalSince1970: 610))
            ]), sensorSource: ReplaySensorSource(samples: []), clock: ReplayClock(), rideStore: store)

        try await tracker.resumeIfNeeded(from: store)
        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 4_000, accuracy: 1)
    }

    @MainActor
    func testRealBacktrackingIsStillAllowed() async {
        let tracker = tracker(fixes: [
            fix(fractionAlongRoute: 0.5, offRouteMeters: 0, time: 0),
            fix(fractionAlongRoute: 0.4, offRouteMeters: 0, time: 20),
        ])

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 400, accuracy: 1)
    }

    @MainActor
    func testFixWithinCorridorAdvancesDistanceAlongRoute() async {
        let tracker = tracker(fixes: [fix(fractionAlongRoute: 0.5, offRouteMeters: 10, time: 0)])

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, segmentEnd * 0.5, accuracy: 1.0)
        XCTAssertEqual(tracker.track.count, 1)
    }

    @MainActor
    func testFixExactlyAtCorridorBoundaryAdvancesDistanceAlongRoute() async {
        let tracker = tracker(fixes: [fix(fractionAlongRoute: 0.5, offRouteMeters: 50, time: 0)])

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, segmentEnd * 0.5, accuracy: 1.0)
        XCTAssertEqual(tracker.track.count, 1)
    }

    @MainActor
    func testFixBeyondCorridorDoesNotAdvanceButIsRecorded() async {
        let fixes = [
            fix(fractionAlongRoute: 0.3, offRouteMeters: 10, time: 0),
            fix(fractionAlongRoute: 0.8, offRouteMeters: 51, time: 1),
        ]
        let tracker = tracker(fixes: fixes)

        await tracker.start()

        XCTAssertEqual(
            tracker.distanceAlongRouteMeters, segmentEnd * 0.3, accuracy: 1.0,
            "an off-route fix must not move distance-along-route")
        XCTAssertEqual(tracker.track.count, 2, "the off-route fix must still be recorded in the raw track")
    }

    @MainActor
    func testFixReturningToCorridorResumesAdvancing() async {
        let fixes = [
            fix(fractionAlongRoute: 0.2, offRouteMeters: 10, time: 0),
            fix(fractionAlongRoute: 0.6, offRouteMeters: 60, time: 1),
            fix(fractionAlongRoute: 0.9, offRouteMeters: 5, time: 2),
        ]
        let tracker = tracker(fixes: fixes)

        await tracker.start()

        XCTAssertEqual(tracker.distanceAlongRouteMeters, segmentEnd * 0.9, accuracy: 1.0)
        XCTAssertEqual(tracker.track.count, 3)
    }
}

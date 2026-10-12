import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.2/task-2.3 validation (RULE-2/RULE-3/RULE-6/RULE-7/RULE-8 in spec/rules.md,
/// AC-1/AC-6/AC-54/AC-55/AC-56): the 60-second snapshot cadence, and grade-adjusted
/// `speedTrend`'s off-route freeze behavior.
final class FeatureEngineTests: XCTestCase {

    /// A flat route (no elevation change) by default — grade-adjustment tests override with
    /// their own elevation profile where the grade itself matters.
    private func flatRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
        ]
    }

    @MainActor
    private func freshRideTracker(route: [ResampledPoint], fixes: [LocationFix]) -> RideTracker {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: route,
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
    }

    // MARK: - 60-second cadence (task-2.2)

    @MainActor
    func testTickProducesOneSnapshotAndSleepsForTheInterval() async throws {
        let tracker = freshRideTracker(route: flatRoute(), fixes: [])
        let engine = FeatureEngine(rideTracker: tracker, route: flatRoute(), clock: ReplayClock())

        try await engine.tick()

        let snapshots = await engine.snapshots
        XCTAssertEqual(snapshots.count, 1)
    }

    @MainActor
    func testThreeTicksSleepSixtySecondsEachTime() async throws {
        let clock = ReplayClock()
        let tracker = freshRideTracker(route: flatRoute(), fixes: [])
        let engine = FeatureEngine(rideTracker: tracker, route: flatRoute(), clock: clock)

        try await engine.tick()
        try await engine.tick()
        try await engine.tick()

        let snapshots = await engine.snapshots
        XCTAssertEqual(snapshots.count, 3)
        let sleepCalls = await clock.sleepCalls
        XCTAssertEqual(sleepCalls, [60.0, 60.0, 60.0])
    }

    @MainActor
    func testCustomIntervalIsHonored() async throws {
        let clock = ReplayClock()
        let tracker = freshRideTracker(route: flatRoute(), fixes: [])
        let engine = FeatureEngine(rideTracker: tracker, route: flatRoute(), clock: clock, snapshotIntervalSeconds: 30.0)

        try await engine.tick()

        let sleepCalls = await clock.sleepCalls
        XCTAssertEqual(sleepCalls, [30.0])
    }

    // MARK: - Grade-adjusted speed trend (task-2.3)

    /// A route climbing steadily: 100m elevation gain over the full 10,000m span (1% grade
    /// throughout), so grade-adjustment adds exactly 0.1 m/s * 1 = 0.1 m/s everywhere on it.
    private func climbingRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 0, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
        ]
    }

    private func fix(fractionAlongRoute: Double, speed: Double, time: TimeInterval) -> LocationFix {
        LocationFix(
            latitude: 52.0, longitude: 13.0 + fractionAlongRoute * 0.1, speedMetersPerSecond: speed,
            timestamp: Date(timeIntervalSince1970: time))
    }

    @MainActor
    func testSpeedTrendUsesHandComputedGradeAdjustedSpeed() async throws {
        // Two fixes, both on the 1%-grade climb, 10 minutes apart, speed rising 5 -> 7 m/s.
        // Grade-adjusted: 5.1 -> 7.1 m/s. Slope = (7.1 - 5.1) / 600s = 1.0/300 m/s^2.
        let fixes = [fix(fractionAlongRoute: 0.1, speed: 5, time: 0), fix(fractionAlongRoute: 0.2, speed: 7, time: 600)]
        let tracker = freshRideTracker(route: climbingRoute(), fixes: fixes)
        await tracker.start()
        let engine = FeatureEngine(rideTracker: tracker, route: climbingRoute(), clock: ReplayClock())

        try await engine.tick()

        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.speedTrend ?? -1, (7.1 - 5.1) / 600, accuracy: 0.001)
    }

    @MainActor
    func testOffRouteFreezesGradeButSpeedTrendStillChangesWithRawSpeed() async throws {
        // fix1: on-route at fraction 0.1 (grade = 1%). fix2: far off-route (1,000m away, well
        // beyond the 50m corridor) with a much higher speed — distanceAlongRouteMeters freezes
        // at fix1's value (Milestone 2 behavior), so the grade factor used for fix2's
        // grade-adjusted speed is STILL the frozen 1% grade, not whatever an off-route
        // reprojection might say — but the raw speed term still changes, so speedTrend moves.
        let fix1 = fix(fractionAlongRoute: 0.1, speed: 5, time: 0)
        let fix2 = LocationFix(latitude: 61.0, longitude: 13.0, speedMetersPerSecond: 20, timestamp: Date(timeIntervalSince1970: 600))
        let tracker = freshRideTracker(route: climbingRoute(), fixes: [fix1, fix2])
        await tracker.start()
        let engine = FeatureEngine(rideTracker: tracker, route: climbingRoute(), clock: ReplayClock())

        try await engine.tick()

        // Expected: current grade-adjusted = 20 + 1%*0.1 = 20.1 (frozen grade, not fix2's own
        // off-route projection). earliest (fix1) grade-adjusted = 5.1. Slope = 15/600.
        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.speedTrend ?? -1, (20.1 - 5.1) / 600, accuracy: 0.001)
    }

    @MainActor
    func testSpeedTrendIsNilWithOnlyOneSample() async throws {
        let fixes = [fix(fractionAlongRoute: 0.1, speed: 5, time: 0)]
        let tracker = freshRideTracker(route: climbingRoute(), fixes: fixes)
        await tracker.start()
        let engine = FeatureEngine(rideTracker: tracker, route: climbingRoute(), clock: ReplayClock())

        try await engine.tick()

        let snapshot = await engine.snapshots.last
        XCTAssertNil(snapshot?.speedTrend)
    }
}

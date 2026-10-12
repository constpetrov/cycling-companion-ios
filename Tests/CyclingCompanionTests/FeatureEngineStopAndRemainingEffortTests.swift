import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.5 validation (RULE-12/RULE-13/RULE-14 in spec/rules.md, AC-9/AC-10/AC-37/AC-38/
/// AC-54/AC-55). No sensor data involved, so the plain `ReplayLocationSource`/
/// `ReplaySensorSource` fakes are fine here — no cross-stream ordering concern (unlike
/// task-2.4's `hrDrift`/`cadenceDrop`).
final class FeatureEngineStopAndRemainingEffortTests: XCTestCase {

    private let totalRouteDistanceMeters = 10_000.0

    private func flatRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
            ResampledPoint(
                latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: totalRouteDistanceMeters),
        ]
    }

    private func fix(fractionAlongRoute: Double, speed: Double, time: TimeInterval) -> LocationFix {
        LocationFix(
            latitude: 52.0, longitude: 13.0 + fractionAlongRoute * 0.1, speedMetersPerSecond: speed,
            timestamp: Date(timeIntervalSince1970: time))
    }

    @MainActor
    private func replay(fixes: [LocationFix]) async throws -> FeatureEngine {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: flatRoute(),
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
        await tracker.start()
        let engine = FeatureEngine(rideTracker: tracker, route: flatRoute(), clock: ReplayClock())
        try await engine.tick()
        return engine
    }

    // MARK: - Stop detection boundary (AC-37/AC-38)

    @MainActor
    func testPauseJustUnderThreeMinutesIsNotAStop() async throws {
        let fixes = [
            fix(fractionAlongRoute: 0.01, speed: 5, time: 0),
            fix(fractionAlongRoute: 0.011, speed: 0.3, time: 10), // pause starts
            fix(fractionAlongRoute: 0.011, speed: 0.3, time: 189), // 179s pause — just under 180s
            fix(fractionAlongRoute: 0.02, speed: 5, time: 199), // resumes
        ]
        let engine = try await replay(fixes: fixes)

        // Not a qualifying stop, so "since last stop" falls back to since ride start (t=0).
        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.timeSinceLastStopSeconds ?? -1, 199, accuracy: 0.001)
    }

    @MainActor
    func testPauseOfAtLeastThreeMinutesIsAStop() async throws {
        let fixes = [
            fix(fractionAlongRoute: 0.01, speed: 5, time: 0),
            fix(fractionAlongRoute: 0.011, speed: 0.3, time: 10), // pause starts
            fix(fractionAlongRoute: 0.011, speed: 0.3, time: 190), // 180s pause — exactly at the minimum
            fix(fractionAlongRoute: 0.02, speed: 5, time: 200), // resumes
        ]
        let engine = try await replay(fixes: fixes)

        // Qualifying stop, ending at t=190 — "since last stop" is relative to that, not ride start.
        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.timeSinceLastStopSeconds ?? -1, 10, accuracy: 0.001)
    }

    @MainActor
    func testNoStopEverFallsBackToSinceRideStart() async throws {
        let fixes = [fix(fractionAlongRoute: 0.01, speed: 5, time: 0), fix(fractionAlongRoute: 0.02, speed: 5, time: 50)]
        let engine = try await replay(fixes: fixes)

        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.timeSinceLastStopSeconds ?? -1, 50, accuracy: 0.001)
    }

    // MARK: - Remaining effort and off-route freeze (AC-9/AC-54/AC-55)

    @MainActor
    func testRemainingEffortMatchesTotalMinusDistanceAlongRoute() async throws {
        let fixes = [fix(fractionAlongRoute: 0.3, speed: 5, time: 0)]
        let engine = try await replay(fixes: fixes)

        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.remainingEffortMeters ?? -1, 7_000, accuracy: 0.01)
    }

    @MainActor
    func testRemainingEffortStaysFrozenThroughAnOffRouteExcursion() async throws {
        let onRoute = fix(fractionAlongRoute: 0.3, speed: 5, time: 0)
        let offRoute = LocationFix(
            latitude: 61.0, longitude: 13.0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 10))
        let engine = try await replay(fixes: [onRoute, offRoute])

        // distanceAlongRouteMeters freezes at the on-route fix's value (3,000m); remaining
        // effort must reflect that frozen value, not an off-route reprojection.
        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.remainingEffortMeters ?? -1, 7_000, accuracy: 0.01)
    }
}

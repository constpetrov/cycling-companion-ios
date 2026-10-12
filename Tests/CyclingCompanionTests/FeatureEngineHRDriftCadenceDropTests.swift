import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.4 validation (RULE-9/RULE-10/RULE-11 in spec/rules.md, AC-7/AC-8/AC-11/AC-12/AC-56).
///
/// Uses the Clock-paced `RideFixtureReplayDriver` (task-3.2, Milestone 2), not the plain
/// `ReplayLocationSource`/`ReplaySensorSource` — `hrDrift`/`cadenceDrop` depend on `track[]`'s
/// *historical* sensor tagging, which the plain fakes can't guarantee relative ordering for
/// (each yields its whole array synchronously, with no shared timeline between the two
/// streams). The paced driver walks both streams through the identical combined,
/// timestamp-ordered entry list in lockstep, so a sensor entry nominally before a location
/// entry reliably lands before it. A `ScaledRealClock` with a tiny scale keeps this fast in
/// real wall-clock terms even though some fixtures span a full nominal hour.
final class FeatureEngineHRDriftCadenceDropTests: XCTestCase {

    /// Flat (0% grade) so grade-adjusted speed equals raw speed exactly — keeps the
    /// hand-computed expected values simple.
    private func flatRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
        ]
    }

    private func locationEntry(timestamp: TimeInterval, fractionAlongRoute: Double, speed: Double) -> RideFixtureEntry {
        RideFixtureEntry(
            kind: "location", timestamp: timestamp, latitude: 52.0, longitude: 13.0 + fractionAlongRoute * 0.1,
            speedMetersPerSecond: speed, heartRateBPM: nil, cadenceRPM: nil)
    }

    private func sensorEntry(timestamp: TimeInterval, heartRateBPM: Int?, cadenceRPM: Int?) -> RideFixtureEntry {
        RideFixtureEntry(
            kind: "sensor", timestamp: timestamp, latitude: nil, longitude: nil, speedMetersPerSecond: nil,
            heartRateBPM: heartRateBPM, cadenceRPM: cadenceRPM)
    }

    @MainActor
    private func replay(entries: [RideFixtureEntry]) async throws -> (RideTracker, FeatureEngine) {
        let clock = ScaledRealClock(scale: 0.0001)
        let driver = RideFixtureReplayDriver(entries: entries, clock: clock)
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: flatRoute(),
            locationSource: driver, sensorSource: driver, clock: clock, rideStore: rideStore)
        await tracker.start()
        let engine = FeatureEngine(rideTracker: tracker, route: flatRoute(), clock: clock)
        try await engine.tick()
        return (tracker, engine)
    }

    // MARK: - hrDrift (AC-7/AC-56)

    @MainActor
    func testHRDriftIsMissingBeforeTheFirstHourMovingTimeThreshold() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 85),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            locationEntry(timestamp: 1_810, fractionAlongRoute: 0.02, speed: 5), // movingTime = 1,800s
        ]
        let (_, engine) = try await replay(entries: entries)

        let snapshot = await engine.snapshots.last
        XCTAssertNil(snapshot?.hrDrift, "1,800s moving time is well under the 3,600s baseline threshold")
    }

    @MainActor
    func testHRDriftIsZeroWhenCurrentMatchesTheFirstHourBaselineExactly() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 85),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            locationEntry(timestamp: 1_810, fractionAlongRoute: 0.02, speed: 5),
            locationEntry(timestamp: 3_610, fractionAlongRoute: 0.03, speed: 5), // movingTime = 3,600s
        ]
        let (_, engine) = try await replay(entries: entries)

        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.hrDrift ?? -1, 0, accuracy: 0.001)
    }

    @MainActor
    func testHRDriftIsPositiveWhenCurrentHRExceedsTheFirstHourBaseline() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 85),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            locationEntry(timestamp: 1_810, fractionAlongRoute: 0.02, speed: 5),
            locationEntry(timestamp: 3_610, fractionAlongRoute: 0.03, speed: 5), // baseline window ends here
            sensorEntry(timestamp: 3_695, heartRateBPM: 175, cadenceRPM: 85),
            locationEntry(timestamp: 3_700, fractionAlongRoute: 0.04, speed: 5), // outside the baseline window
        ]
        let (_, engine) = try await replay(entries: entries)

        // baseline ratio = 140/5 = 28; current ratio = 175/5 = 35; drift = 35/28 - 1 = 0.25.
        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.hrDrift ?? -1, 0.25, accuracy: 0.001)
    }

    @MainActor
    func testHRDriftIsMissingDuringAHeartRateDropoutEvenPastTheThreshold() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 85),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            locationEntry(timestamp: 1_810, fractionAlongRoute: 0.02, speed: 5),
            locationEntry(timestamp: 3_610, fractionAlongRoute: 0.03, speed: 5),
            sensorEntry(timestamp: 3_695, heartRateBPM: nil, cadenceRPM: 85), // dropout
            locationEntry(timestamp: 3_700, fractionAlongRoute: 0.04, speed: 5),
        ]
        let (_, engine) = try await replay(entries: entries)

        let snapshot = await engine.snapshots.last
        XCTAssertNil(snapshot?.hrDrift, "a dropped-out current HR reading must not fall back to a stale value")
    }

    // MARK: - cadenceDrop (AC-8/AC-12)

    @MainActor
    func testCadenceDropIsNonMissingOnceAFirstReadingExists() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 90),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            sensorEntry(timestamp: 20, heartRateBPM: 140, cadenceRPM: 80),
            locationEntry(timestamp: 30, fractionAlongRoute: 0.02, speed: 5),
        ]
        let (_, engine) = try await replay(entries: entries)

        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.cadenceDrop, -10, "current (80) minus the ride's first reading (90)")
    }

    @MainActor
    func testCadenceDropIsMissingDuringACadenceDropout() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 90),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            sensorEntry(timestamp: 20, heartRateBPM: 140, cadenceRPM: nil), // dropout
            locationEntry(timestamp: 30, fractionAlongRoute: 0.02, speed: 5),
        ]
        let (_, engine) = try await replay(entries: entries)

        let snapshot = await engine.snapshots.last
        XCTAssertNil(snapshot?.cadenceDrop)
    }

    @MainActor
    func testCadenceDropIsNonMissingAfterRecoveringFromADropout() async throws {
        let entries = [
            sensorEntry(timestamp: 5, heartRateBPM: 140, cadenceRPM: 90),
            locationEntry(timestamp: 10, fractionAlongRoute: 0.01, speed: 5),
            sensorEntry(timestamp: 20, heartRateBPM: 140, cadenceRPM: nil), // dropout
            locationEntry(timestamp: 30, fractionAlongRoute: 0.02, speed: 5),
            sensorEntry(timestamp: 40, heartRateBPM: 140, cadenceRPM: 95), // recovered
            locationEntry(timestamp: 50, fractionAlongRoute: 0.03, speed: 5),
        ]
        let (_, engine) = try await replay(entries: entries)

        let snapshot = await engine.snapshots.last
        XCTAssertEqual(snapshot?.cadenceDrop, 5, "current (95) minus the ride's first reading (90), unaffected by the dropout in between")
    }
}

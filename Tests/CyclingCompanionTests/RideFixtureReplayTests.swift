import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.2 validation (AC-21/AC-22): replaying `simple_ride.json` through `RideTracker` and
/// `RideRecorder` produces a finalized `PersistedRide` matching values hand-computed from the
/// fixture itself; replaying under a faster virtual clock produces identical results to a
/// real-time-paced run.
///
/// Expected values, hand-derived from `simple_ride.json` (not by calling production code):
/// the route is a straight 10,000m segment from longitude 13.0 to 13.1 at latitude 52.0, so
/// each location sample's `distanceAlongRouteMeters` is `(longitude - 13.0) / 0.1 * 10,000`.
/// Location fixes land at t=0.2 (0m), t=0.4 (1,000m), t=0.8 (2,000m), t=1.0 (3,000m) — three
/// intervals of elapsed time (0.2s, 0.4s, 0.2s), all above the 0.5 m/s moving threshold, for a
/// total moving time of 0.8s (well under the 30s ETA threshold, so no ETA is ever reported).
/// The sensor stream sets heart rate/cadence to 140/85 at t=0.0 (before the first location fix)
/// and drops heart rate to nil at t=0.6 (before the third location fix, at t=0.8).
final class RideFixtureReplayTests: XCTestCase {

    private let totalRouteDistanceMeters = 10_000.0

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(
                latitude: 52.0, longitude: 13.1, elevationMeters: nil, cumulativeDistanceMeters: totalRouteDistanceMeters),
        ]
    }

    private func loadFixture() throws -> [RideFixtureEntry] {
        try RideFixtureLoader.load(resource: "simple_ride", bundle: Bundle(for: Self.self))
    }

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func replay(clock: Clock, rideStore: RideStore) async throws -> RideTracker {
        let entries = try loadFixture()
        let driver = RideFixtureReplayDriver(entries: entries, clock: clock)
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: route(),
            locationSource: driver, sensorSource: driver, clock: clock, rideStore: rideStore)
        await tracker.start()
        return tracker
    }

    @MainActor
    func testReplayingAFixtureProducesAFinalizedRideMatchingIndependentlyComputedStats() async throws {
        // A real (if tiny-scaled) clock, not `ReplayClock` — the two replay streams only stay
        // in the fixture's original relative order because each actually sleeps proportionally
        // to the inter-entry delay; a clock that doesn't suspend at all gives the scheduler no
        // signal to preserve that order, which is exactly the determinism risk this task's
        // own risk hotspot calls out.
        let store = freshRideStore()
        let tracker = try await replay(clock: ScaledRealClock(scale: 0.01), rideStore: store)

        XCTAssertEqual(tracker.distanceAlongRouteMeters, 3_000, accuracy: 0.01)
        XCTAssertEqual(tracker.movingTimeSeconds, 0.8, accuracy: 0.001)
        XCTAssertNil(tracker.etaSeconds, "0.8s moving time is well under the 30s ETA threshold")
        XCTAssertEqual(tracker.track.count, 4)
        XCTAssertEqual(tracker.track[0].heartRateBPM, 140)
        XCTAssertEqual(tracker.track[0].cadenceRPM, 85)
        XCTAssertEqual(tracker.track[2].heartRateBPM, nil, "the t=0.6 dropout must precede the t=0.8 fix")
        XCTAssertEqual(tracker.track[2].cadenceRPM, 85)

        let recorder = RideRecorder(rideStore: store)
        try await recorder.finalize(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1), totalDistanceMeters: tracker.distanceAlongRouteMeters,
            totalMovingTimeSeconds: tracker.movingTimeSeconds, track: tracker.track)

        let finalized = try await store.fetch(rideId: "ride-1")
        XCTAssertNotNil(finalized?.endTime)
        XCTAssertEqual(finalized?.totalDistanceMeters ?? -1, 3_000, accuracy: 0.01)
        XCTAssertEqual(finalized?.totalMovingTimeSeconds ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(finalized?.track.count, 4)
    }

    /// AC-22: a real-time-paced run (scale 1.0, ~1 wall-clock second) and a faster
    /// virtual-clock run (scale 0.05, ~50 wall-clock milliseconds) of the identical fixture
    /// must produce identical map-matching/moving-time/ETA/track results — pacing speed must
    /// never change what's computed, only how long replay takes.
    @MainActor
    func testReplayUnderAFasterVirtualClockMatchesARealTimePacedRun() async throws {
        let realTimeTracker = try await replay(clock: ScaledRealClock(scale: 1.0), rideStore: freshRideStore())
        let fasterTracker = try await replay(clock: ScaledRealClock(scale: 0.05), rideStore: freshRideStore())

        XCTAssertEqual(realTimeTracker.distanceAlongRouteMeters, fasterTracker.distanceAlongRouteMeters, accuracy: 0.01)
        XCTAssertEqual(realTimeTracker.movingTimeSeconds, fasterTracker.movingTimeSeconds, accuracy: 0.001)
        XCTAssertEqual(realTimeTracker.etaSeconds, fasterTracker.etaSeconds)
        XCTAssertEqual(realTimeTracker.track.count, fasterTracker.track.count)
        for (realSample, fasterSample) in zip(realTimeTracker.track, fasterTracker.track) {
            XCTAssertEqual(realSample.timestamp, fasterSample.timestamp)
            XCTAssertEqual(realSample.heartRateBPM, fasterSample.heartRateBPM)
            XCTAssertEqual(realSample.cadenceRPM, fasterSample.cadenceRPM)
        }
    }
}

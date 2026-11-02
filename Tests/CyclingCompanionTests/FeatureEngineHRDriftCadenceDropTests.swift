import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.4 validation (RULE-9/RULE-10/RULE-11 in spec/rules.md, AC-7/AC-8/AC-11/AC-12/AC-56).
///
/// Feeds the fixture's entries one at a time, waiting for `RideTracker` to take each before sending the
/// next. `hrDrift`/`cadenceDrop` depend on which sensor reading each `track[]` sample was tagged with, and
/// the tracker reads its two streams independently, so anything looser lets a location overtake the
/// sensor reading before it on a slow machine.
final class FeatureEngineHRDriftCadenceDropTests: XCTestCase {

    private struct FedStreams: LocationSource, SensorSource {
        let locations: AsyncStream<LocationFix>
        let sensors: AsyncStream<SensorSample>
        func locationUpdates() -> AsyncStream<LocationFix> { locations }
        func sensorUpdates() -> AsyncStream<SensorSample> { sensors }
    }

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
        let (locations, locationFeed) = AsyncStream.makeStream(of: LocationFix.self)
        let (sensors, sensorFeed) = AsyncStream.makeStream(of: SensorSample.self)
        let streams = FedStreams(locations: locations, sensors: sensors)
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let tracker = RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), route: flatRoute(),
            locationSource: streams, sensorSource: streams, clock: clock, rideStore: rideStore)
        let running = Task { await tracker.start() }
        for entry in entries {
            if let fix = entry.asLocationFix {
                let taken = tracker.track.count + 1
                locationFeed.yield(fix)
                while tracker.track.count < taken { await Task.yield() }
            } else if let sample = entry.asSensorSample {
                sensorFeed.yield(sample)
                while tracker.currentHeartRateBPM != sample.heartRateBPM || tracker.currentCadenceRPM != sample.cadenceRPM {
                    await Task.yield()
                }
            }
        }
        locationFeed.finish()
        sensorFeed.finish()
        await running.value
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

    // MARK: - cadenceDrop (milestone 12, AC-42 to AC-48)

    /// A cadence reading followed by a location fix half a second later, so the fix carries it.
    private func cadenceFix(_ timestamp: TimeInterval, _ cadenceRPM: Int?) -> [RideFixtureEntry] {
        [
            sensorEntry(timestamp: timestamp - 0.5, heartRateBPM: 140, cadenceRPM: cadenceRPM),
            locationEntry(timestamp: timestamp, fractionAlongRoute: timestamp / 10_000, speed: 5),
        ]
    }

    @MainActor
    private func cadenceDrop(_ fixes: [[RideFixtureEntry]]) async throws -> Int? {
        let (_, engine) = try await replay(entries: fixes.flatMap { $0 })
        return await engine.snapshots.last?.cadenceDrop
    }

    /// AC-44: the baseline window (10 min from the first pedaling reading at 10 s) ends at 610 s.
    @MainActor
    func testCadenceDropIsMissingBeforeTheBaselineWindowEnds() async throws {
        let drop = try await cadenceDrop([cadenceFix(10, 90), cadenceFix(300, 80), cadenceFix(609, 80)])
        XCTAssertNil(drop)
    }

    /// AC-45, AC-42: at exactly 610 s it is computed. Baseline (90, 80, 80) = 83.33; the last 5 min
    /// (310...610) hold 80, 80 → 80 − 83.33 = −3.33, rounded to −3.
    @MainActor
    func testCadenceDropIsComputedWhenTheBaselineWindowEndsExactly() async throws {
        let drop = try await cadenceDrop([cadenceFix(10, 90), cadenceFix(500, 80), cadenceFix(610, 80)])
        XCTAssertEqual(drop, -3)
    }

    /// AC-46: later readings never join the baseline. Baseline = 90 (10 s, 600 s); current
    /// (700...1000) = 70 → −20.
    @MainActor
    func testBaselineUsesOnlyTheFirstTenMinutesOfPedaling() async throws {
        let drop = try await cadenceDrop([
            cadenceFix(10, 90), cadenceFix(600, 90), cadenceFix(700, 70), cadenceFix(900, 70), cadenceFix(1_000, 70),
        ])
        XCTAssertEqual(drop, -20)
    }

    /// AC-43: zeros at the start don't start the baseline, and zeros in either window are ignored.
    /// First pedaling is at 60 s, so the baseline runs to 660 s.
    @MainActor
    func testZeroCadenceIsIgnoredInBothAverages() async throws {
        let drop = try await cadenceDrop([
            cadenceFix(10, 0), cadenceFix(60, 90), cadenceFix(400, 90), cadenceFix(550, 0), cadenceFix(660, 0),
        ])
        XCTAssertEqual(drop, 0, "baseline 90 (60 s, 400 s), current 90 (400 s); every 0 ignored")
    }

    /// AC-47: a long descent with no pedaling in the last 5 minutes.
    @MainActor
    func testCadenceDropIsMissingWithNoPedalingInTheLastFiveMinutes() async throws {
        let drop = try await cadenceDrop([
            cadenceFix(10, 90), cadenceFix(600, 90), cadenceFix(700, 0), cadenceFix(1_000, 0),
        ])
        XCTAssertNil(drop)
    }

    /// AC-48: at now = 1000 s a reading at 700 s (exactly 5 min old) counts and one at 699 s doesn't.
    /// Baseline 90; current (60, 60) = 60 → −30. Including the 30 at 699 s would give −40.
    @MainActor
    func testCurrentWindowIncludesAReadingExactlyFiveMinutesOld() async throws {
        let drop = try await cadenceDrop([
            cadenceFix(10, 90), cadenceFix(699, 30), cadenceFix(700, 60), cadenceFix(1_000, 60),
        ])
        XCTAssertEqual(drop, -30)
    }

    /// A sensor dropout (nil) inside the current window is ignored like coasting.
    @MainActor
    func testCadenceDropoutInsideTheWindowIsIgnored() async throws {
        let drop = try await cadenceDrop([
            cadenceFix(10, 90), cadenceFix(700, 80), cadenceFix(800, nil), cadenceFix(1_000, nil),
        ])
        XCTAssertEqual(drop, -10)
    }
}

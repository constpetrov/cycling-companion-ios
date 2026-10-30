import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.5 validation (RULE-27/RULE-28 in spec/rules.md, AC-47 through AC-53).
final class DemoModeTests: XCTestCase {

    private func route(points: [PersistedPointInput]) -> PersistedRoute {
        PersistedRoute(
            id: "current", hash: "hash", totalDistanceMeters: points.last?.cumulativeDistanceMeters ?? 0,
            totalClimbingMeters: nil, status: "ready", points: points, pois: [])
    }

    func testDemoFollowsCurrentRouteIncludingBendsAndFinish() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let currentRoute = route(points: [
            PersistedPointInput(latitude: 52.1, longitude: 4.3, elevationMeters: nil, cumulativeDistanceMeters: 0),
            PersistedPointInput(latitude: 52.101, longitude: 4.3, elevationMeters: nil, cumulativeDistanceMeters: 100),
            PersistedPointInput(latitude: 52.101, longitude: 4.301, elevationMeters: nil, cumulativeDistanceMeters: 200),
        ])

        let fixes = DemoFixture.locationFixes(for: currentRoute, startTime: start)

        let first = try XCTUnwrap(fixes.first)
        let last = try XCTUnwrap(fixes.last)
        XCTAssertEqual(first.latitude, 52.1)
        XCTAssertEqual(first.longitude, 4.3)
        XCTAssertEqual(first.timestamp, start)
        XCTAssertEqual(last.latitude, 52.101)
        XCTAssertEqual(last.longitude, 4.301)
        XCTAssertEqual(last.timestamp.timeIntervalSince(start), 40, accuracy: 0.001)
        XCTAssertEqual(last.speedMetersPerSecond, 0)
        XCTAssertTrue(fixes.contains { $0.latitude == 52.101 && $0.longitude == 4.3 })
        for (previous, next) in zip(fixes, fixes.dropFirst()) {
            let gap = next.timestamp.timeIntervalSince(previous.timestamp)
            XCTAssertGreaterThan(gap, 0)
            XCTAssertLessThanOrEqual(gap, 5)
            XCTAssertTrue(next.longitude == 4.3 || next.latitude == 52.101, "must follow the bend, not cut across it")
        }
    }

    func testDemoHandlesDuplicatePointsAndShortFinalSegment() throws {
        let currentRoute = route(points: [
            PersistedPointInput(latitude: 52, longitude: 4, elevationMeters: nil, cumulativeDistanceMeters: 0),
            PersistedPointInput(latitude: 52, longitude: 4, elevationMeters: nil, cumulativeDistanceMeters: 0),
            PersistedPointInput(latitude: 52.0001, longitude: 4, elevationMeters: nil, cumulativeDistanceMeters: 10),
        ])
        let start = Date()
        let fixes = DemoFixture.locationFixes(for: currentRoute, startTime: start)

        XCTAssertEqual(fixes.count, 2)
        XCTAssertEqual(try XCTUnwrap(fixes.last).timestamp.timeIntervalSince(start), 2, accuracy: 0.001)
    }

    func testDemoDoesNotSubstituteBundledTrackForEmptyOrStationaryRoute() {
        let point = PersistedPointInput(latitude: 52, longitude: 4, elevationMeters: nil, cumulativeDistanceMeters: 0)
        for points in [[], [point], [point, point]] {
            XCTAssertTrue(DemoFixture.locationFixes(for: route(points: points), startTime: Date()).isEmpty)
        }
    }

    // MARK: - Speed clamping, three-point boundary at each end (AC-47/48/49/50/51)

    func testSpeedWithinRangeAppliesAsRequested() {
        XCTAssertEqual(DemoMode.clampSpeed(10), 10)
    }

    func testSpeedAtUpperBoundaryAppliesAsRequested() {
        XCTAssertEqual(DemoMode.clampSpeed(20), 20)
    }

    func testSpeedBeyondUpperBoundaryIsClampedTo20() {
        XCTAssertEqual(DemoMode.clampSpeed(25), 20)
    }

    func testSpeedAtLowerBoundaryAppliesAsRequested() {
        XCTAssertEqual(DemoMode.clampSpeed(1), 1)
    }

    func testSpeedBelowLowerBoundaryIsClampedTo1() {
        XCTAssertEqual(DemoMode.clampSpeed(0.5), 1)
    }

    // MARK: - Debug force-check control (AC-52)

    func testForceRequestedRunsTheCheckImmediatelyRegardlessOfCadence() {
        let shouldCheck = AdvisorCheckCadence.shouldCheckNow(
            forceRequested: true, secondsSinceLastCheck: 0, cadenceSeconds: 60)

        XCTAssertTrue(shouldCheck)
    }

    func testWithoutForceTheCheckWaitsOutTheCadence() {
        let shouldCheck = AdvisorCheckCadence.shouldCheckNow(
            forceRequested: false, secondsSinceLastCheck: 10, cadenceSeconds: 60)

        XCTAssertFalse(shouldCheck)
    }

    func testWithoutForceTheCheckStillRunsOnceTheCadenceElapses() {
        let shouldCheck = AdvisorCheckCadence.shouldCheckNow(
            forceRequested: false, secondsSinceLastCheck: 60, cadenceSeconds: 60)

        XCTAssertTrue(shouldCheck)
    }

    // MARK: - Replay driver speed-scaling (RULE-27)

    func testReplayDriverScalesInterSampleDelayByOneOverSpeed() async {
        let clock = ReplayClock()
        let fixes = [
            LocationFix(latitude: 0, longitude: 0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 0)),
            LocationFix(latitude: 0, longitude: 0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 10)),
        ]
        let driver = DemoModeReplayDriver(locationFixes: fixes, sensorSamples: [], clock: clock, speed: 5)

        var received: [LocationFix] = []
        for await fix in driver.locationUpdates() {
            received.append(fix)
        }

        XCTAssertEqual(received.count, 2)
        let sleepCalls = await clock.sleepCalls
        XCTAssertEqual(sleepCalls, [2]) // 10s of fixture time / 5x speed == 2s
    }

    func testReplayDriverClampsAnOutOfRangeSpeedBeforeScaling() async {
        let clock = ReplayClock()
        let fixes = [
            LocationFix(latitude: 0, longitude: 0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 0)),
            LocationFix(latitude: 0, longitude: 0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 20)),
        ]
        let driver = DemoModeReplayDriver(locationFixes: fixes, sensorSamples: [], clock: clock, speed: 100)

        for await _ in driver.locationUpdates() {}

        let sleepCalls = await clock.sleepCalls
        XCTAssertEqual(sleepCalls, [1]) // speed clamped to 20x, so 20s / 20 == 1s
    }

    // MARK: - Combined, timestamp-ordered replay across both streams

    func testLocationAndSensorStreamsReplayFromOneSharedCombinedTimeline() async {
        let clock = ReplayClock()
        let fixes = [LocationFix(latitude: 0, longitude: 0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 0))]
        let samples = [SensorSample(heartRateBPM: 140, cadenceRPM: 80, timestamp: Date(timeIntervalSince1970: 5))]
        let driver = DemoModeReplayDriver(locationFixes: fixes, sensorSamples: samples, clock: clock, speed: 1)

        var receivedFixes: [LocationFix] = []
        var receivedSamples: [SensorSample] = []
        async let locationTask: Void = {
            for await fix in driver.locationUpdates() { receivedFixes.append(fix) }
        }()
        async let sensorTask: Void = {
            for await sample in driver.sensorUpdates() { receivedSamples.append(sample) }
        }()
        _ = await (locationTask, sensorTask)

        XCTAssertEqual(receivedFixes.count, 1)
        XCTAssertEqual(receivedSamples.count, 1)
    }
}

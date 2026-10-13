import XCTest

@testable import CyclingCompanion

/// task-4.5 validation (RULE-27/RULE-28 in spec/rules.md, AC-47 through AC-53).
final class DemoModeTests: XCTestCase {

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

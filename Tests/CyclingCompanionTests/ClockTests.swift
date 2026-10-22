import XCTest

@testable import CyclingCompanion

/// `Clock.now` (RULE-12 in milestone 7's rules.md): every clock reports ride time, so the 30 s
/// no-GPS check can be tested deterministically and runs at replay speed in Demo Mode.
final class ClockTests: XCTestCase {

    func testSystemClockReportsTheWallClock() async {
        let before = Date()
        let now = await SystemClock().now
        let after = Date()

        XCTAssertGreaterThanOrEqual(now, before)
        XCTAssertLessThanOrEqual(now, after)
    }

    func testReplayClockAdvancesByExactlyWhatWasSlept() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = ReplayClock(start: start)

        let initial = await clock.now
        XCTAssertEqual(initial, start)
        try await clock.sleep(for: 29)
        try await clock.sleep(for: 1)
        let later = await clock.now
        XCTAssertEqual(later, start.addingTimeInterval(30))
    }

    /// Review risk hotspot 5: at 20x, 60 s of ride time is 3 s of base time.
    func testSpeedScaledClockRunsRideTimeAtTwentyTimesBaseTime() async throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        let base = ReplayClock(start: origin)
        let clock = SpeedScaledClock(base: base, speed: 20, origin: origin)

        try await clock.sleep(for: 60)

        let baseSlept = await base.sleepCalls
        XCTAssertEqual(baseSlept, [3])
        let rideNow = await clock.now
        XCTAssertEqual(rideNow.timeIntervalSince(origin), 60, accuracy: 0.000_1)
    }

    func testSpeedScaledClockAtOneTimesMatchesItsBase() async throws {
        let origin = Date(timeIntervalSince1970: 1_000)
        let base = ReplayClock(start: origin)
        let clock = SpeedScaledClock(base: base, speed: 1, origin: origin)

        try await clock.sleep(for: 45)

        let rideNow = await clock.now
        let baseNow = await base.now
        XCTAssertEqual(rideNow, baseNow)
    }
}

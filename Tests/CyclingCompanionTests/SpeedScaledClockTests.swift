import XCTest

@testable import CyclingCompanion

/// task-4.1 validation (RULE-7 in spec/rules.md, AC-23).
final class SpeedScaledClockTests: XCTestCase {

    func testSleepScalesByOneOverSpeed() async throws {
        let base = ReplayClock()
        let clock = SpeedScaledClock(base: base, speed: 10)

        try await clock.sleep(for: 60)

        let sleepCalls = await base.sleepCalls
        XCTAssertEqual(sleepCalls, [6])
    }

    func testSpeedOneIsUnscaled() async throws {
        let base = ReplayClock()
        let clock = SpeedScaledClock(base: base, speed: 1)

        try await clock.sleep(for: 60)

        let sleepCalls = await base.sleepCalls
        XCTAssertEqual(sleepCalls, [60])
    }

    func testSpeedTwentyScalesDownToOneTwentieth() async throws {
        let base = ReplayClock()
        let clock = SpeedScaledClock(base: base, speed: 20)

        try await clock.sleep(for: 60)

        let sleepCalls = await base.sleepCalls
        XCTAssertEqual(sleepCalls, [3])
    }
}

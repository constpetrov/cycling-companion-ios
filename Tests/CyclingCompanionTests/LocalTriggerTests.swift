import XCTest

@testable import CyclingCompanion

/// task-3.1 validation (RULE-2/RULE-4 in spec/rules.md, AC-13/AC-14/AC-15/AC-16/AC-17).
final class LocalTriggerTests: XCTestCase {

    private func emptySnapshot() -> FeatureSnapshot {
        FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Crossed threshold triggers regardless of elapsed time (AC-13)

    func testCrossedHRDriftThresholdTriggersEvenWithNoElapsedTimeAndNoStopAhead() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.11)

        let result = LocalTrigger.shouldProceed(
            snapshot: snapshot, hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 0)

        XCTAssertTrue(result)
    }

    func testCrossedSpeedTrendThresholdTriggers() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), speedTrend: -0.3 / (30 * 60) - 0.0001)

        let result = LocalTrigger.shouldProceed(
            snapshot: snapshot, hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 0)

        XCTAssertTrue(result)
    }

    func testCrossedCadenceDropThresholdTriggers() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), cadenceDrop: -15)

        let result = LocalTrigger.shouldProceed(
            snapshot: snapshot, hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 0)

        XCTAssertTrue(result)
    }

    func testFeatureValueJustUnderItsThresholdDoesNotTriggerOnItsOwn() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.09, cadenceDrop: -5)

        let result = LocalTrigger.shouldProceed(
            snapshot: snapshot, hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 0)

        XCTAssertFalse(result)
    }

    // MARK: - Qualifying stop ahead triggers with no threshold crossed (AC-14)

    func testQualifyingStopAheadTriggersWithNoThresholdCrossedAndNoElapsedTime() {
        let result = LocalTrigger.shouldProceed(
            snapshot: emptySnapshot(), hasQualifyingStopAhead: true, secondsSinceLastCheckThatProceeded: 0)

        XCTAssertTrue(result)
    }

    // MARK: - 45-minute fallback boundary (AC-15/AC-16/AC-17)

    func testFewerThanFortyFiveMinutesDoesNotTriggerAbsentTheOtherTwoConditions() {
        let result = LocalTrigger.shouldProceed(
            snapshot: emptySnapshot(), hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 45 * 60 - 1)

        XCTAssertFalse(result)
    }

    func testExactlyFortyFiveMinutesTriggers() {
        let result = LocalTrigger.shouldProceed(
            snapshot: emptySnapshot(), hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 45 * 60)

        XCTAssertTrue(result)
    }

    func testMoreThanFortyFiveMinutesTriggers() {
        let result = LocalTrigger.shouldProceed(
            snapshot: emptySnapshot(), hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 45 * 60 + 1)

        XCTAssertTrue(result)
    }
}

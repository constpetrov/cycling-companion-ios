import XCTest

@testable import CyclingCompanion

/// Milestone 12 task-1.2: AC-30 to AC-41.
final class CrankCadenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

    private func csc(revolutions: UInt16, eventTime: UInt16, withWheel: Bool = false) -> Data {
        var bytes: [UInt8] = [withWheel ? 0x03 : 0x02]
        if withWheel { bytes += [1, 2, 3, 4, 5, 6] }
        return Data(bytes + le16(revolutions) + le16(eventTime))
    }

    // MARK: - Measurement parsing

    func testCyclingSpeedAndCadenceCrankOnly() {
        XCTAssertEqual(
            CrankMeasurement.fromCyclingSpeedAndCadence(csc(revolutions: 10, eventTime: 2048)),
            CrankSample(revolutions: 10, eventTime: 2048))
    }

    func testCyclingSpeedAndCadenceSkipsWheelData() {
        XCTAssertEqual(
            CrankMeasurement.fromCyclingSpeedAndCadence(csc(revolutions: 7, eventTime: 99, withWheel: true)),
            CrankSample(revolutions: 7, eventTime: 99))
    }

    /// AC-41.
    func testWheelOnlyCyclingSpeedAndCadenceHasNoCrankData() {
        XCTAssertNil(CrankMeasurement.fromCyclingSpeedAndCadence(Data([0x01, 1, 2, 3, 4, 5, 6])))
    }

    func testCyclingPowerCrankAfterAllOptionalFields() {
        // Flags: balance (bit 0), torque (bit 2), wheel (bit 4), crank (bit 5) = 0x35.
        let bytes: [UInt8] = le16(0x35) + le16(250) + [50] + le16(1234) + [1, 2, 3, 4, 5, 6] + le16(300) + le16(4096)
        XCTAssertEqual(
            CrankMeasurement.fromCyclingPower(Data(bytes)), CrankSample(revolutions: 300, eventTime: 4096))
    }

    func testCyclingPowerCrankOnly() {
        let bytes: [UInt8] = le16(0x20) + le16(180) + le16(5) + le16(1024)
        XCTAssertEqual(CrankMeasurement.fromCyclingPower(Data(bytes)), CrankSample(revolutions: 5, eventTime: 1024))
    }

    func testCyclingPowerWithoutCrankData() {
        XCTAssertNil(CrankMeasurement.fromCyclingPower(Data(le16(0x00) + le16(200))))
    }

    func testTruncatedPayloadsHaveNoCrankData() {
        XCTAssertNil(CrankMeasurement.fromCyclingSpeedAndCadence(Data([0x02, 1, 0])))
        XCTAssertNil(CrankMeasurement.fromCyclingPower(Data(le16(0x20) + le16(100) + [1])))
    }

    // MARK: - Cadence

    /// AC-30, AC-33: two revolutions in one second is 120 rpm; the first sample has nothing to compare with.
    func testCadenceFromConsecutiveSamples() {
        var calculator = CrankCadenceCalculator()
        XCTAssertNil(calculator.ingest(CrankSample(revolutions: 10, eventTime: 1024), at: t0))
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 12, eventTime: 2048), at: t0 + 1), 120)
    }

    /// AC-31: the same arithmetic for crank data parsed from a cycling power measurement.
    func testCadenceFromCyclingPowerSamples() {
        var calculator = CrankCadenceCalculator()
        let first = CrankMeasurement.fromCyclingPower(Data(le16(0x20) + le16(200) + le16(100) + le16(0)))
        let second = CrankMeasurement.fromCyclingPower(Data(le16(0x20) + le16(210) + le16(101) + le16(683)))
        _ = calculator.ingest(first, at: t0)
        XCTAssertEqual(calculator.ingest(second, at: t0 + 1), 90, "1 rev in 683/1024 s ≈ 89.96 rpm")
    }

    /// AC-32.
    func testCounterAndEventTimeWraparound() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 65_535, eventTime: 65_000), at: t0)
        // +2 revolutions in 65_000 → 512 (wrapped) = 1048 ticks ≈ 1.023 s → 117.25 rpm.
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 1, eventTime: 512), at: t0 + 1), 117)
    }

    /// AC-34, AC-35: a repeated event time keeps the last cadence while under the timeout.
    func testRepeatedEventKeepsLastCadenceWithinTimeout() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 0, eventTime: 0), at: t0)
        _ = calculator.ingest(CrankSample(revolutions: 1, eventTime: 683), at: t0 + 1)
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 1, eventTime: 683), at: t0 + 3.9), 90)
        XCTAssertEqual(calculator.cadence(at: t0 + 3.999), 90)
    }

    /// AC-36: exactly at the timeout cadence is 0.
    func testCoastingAtTimeoutIsZero() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 0, eventTime: 0), at: t0)
        _ = calculator.ingest(CrankSample(revolutions: 1, eventTime: 683), at: t0 + 1)
        XCTAssertEqual(calculator.cadence(at: t0 + 4), 0)
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 1, eventTime: 683), at: t0 + 4), 0)
    }

    /// AC-37: beyond the timeout it stays 0 until a new event.
    func testCoastingBeyondTimeoutStaysZeroUntilANewEvent() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 0, eventTime: 0), at: t0)
        _ = calculator.ingest(CrankSample(revolutions: 1, eventTime: 683), at: t0 + 1)
        XCTAssertEqual(calculator.cadence(at: t0 + 30), 0)
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 2, eventTime: 1366), at: t0 + 31), 90)
    }

    /// AC-38.
    func testCadenceBelowBoundIsReported() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 0, eventTime: 0), at: t0)
        // 4 revs in 1 s = 240 rpm.
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 4, eventTime: 1024), at: t0 + 1), 240)
    }

    /// AC-39.
    func testCadenceAtBoundIsReported() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 0, eventTime: 0), at: t0)
        // 25 revs in 6 s = 250 rpm exactly.
        XCTAssertEqual(calculator.ingest(CrankSample(revolutions: 25, eventTime: 6144), at: t0 + 6), 250)
    }

    /// AC-40: above the bound is no reading, and the last good cadence is kept for later.
    func testCadenceAboveBoundIsDiscarded() {
        var calculator = CrankCadenceCalculator()
        _ = calculator.ingest(CrankSample(revolutions: 0, eventTime: 0), at: t0)
        _ = calculator.ingest(CrankSample(revolutions: 1, eventTime: 683), at: t0 + 1)
        // 5 revs in 1 s = 300 rpm.
        XCTAssertNil(calculator.ingest(CrankSample(revolutions: 6, eventTime: 1707), at: t0 + 2))
        XCTAssertEqual(calculator.cadence(at: t0 + 2.5), 90)
    }

    /// AC-41.
    func testMeasurementWithoutCrankDataIsNoReading() {
        var calculator = CrankCadenceCalculator()
        XCTAssertNil(calculator.ingest(nil, at: t0))
        XCTAssertNil(calculator.cadence(at: t0 + 10))
    }
}

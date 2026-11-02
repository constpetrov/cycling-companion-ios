import XCTest

@testable import CyclingCompanion

/// Milestone 12 task-1.1: AC-27 to AC-29.
final class HeartRateMeasurementTests: XCTestCase {
    func testEightBitValue() {
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x00, 142])), 142)
    }

    func testEightBitValueIgnoresTrailingFields() {
        // Flags 0x10: RR intervals present, 8-bit HR.
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x10, 98, 0x20, 0x03])), 98)
    }

    func testSixteenBitValueIsLittleEndian() {
        XCTAssertEqual(HeartRateMeasurement.bpm(from: Data([0x01, 0x2C, 0x01])), 300)
    }

    func testZeroIsNoReading() {
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x00, 0])))
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x01, 0, 0])))
    }

    func testMalformedPayloadIsNoReading() {
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data()))
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x00])))
        XCTAssertNil(HeartRateMeasurement.bpm(from: Data([0x01, 0x50])))
    }
}

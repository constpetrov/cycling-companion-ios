import XCTest

@testable import CyclingCompanion

/// task-1.1 validation: the replay fake yields a scripted sequence in order.
final class LocationSourceTests: XCTestCase {

    func testReplayLocationSourceYieldsScriptedSequenceInOrder() async {
        let fixes = [
            LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 2.0, timestamp: Date(timeIntervalSince1970: 0)),
            LocationFix(latitude: 52.001, longitude: 13.0, speedMetersPerSecond: 3.0, timestamp: Date(timeIntervalSince1970: 10)),
            LocationFix(latitude: 52.002, longitude: 13.0, speedMetersPerSecond: 4.0, timestamp: Date(timeIntervalSince1970: 20)),
        ]
        let source = ReplayLocationSource(fixes: fixes)

        var received: [LocationFix] = []
        for await fix in source.locationUpdates() {
            received.append(fix)
        }

        XCTAssertEqual(received.map(\.latitude), fixes.map(\.latitude))
        XCTAssertEqual(received.map(\.speedMetersPerSecond), fixes.map(\.speedMetersPerSecond))
        XCTAssertEqual(received.map(\.timestamp), fixes.map(\.timestamp))
    }
}

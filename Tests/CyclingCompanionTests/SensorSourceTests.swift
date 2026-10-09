import XCTest

@testable import CyclingCompanion

/// task-1.2 validation: the replay fake yields a scripted sequence in order, including a
/// dropout (nil field).
final class SensorSourceTests: XCTestCase {

    func testReplaySensorSourceYieldsScriptedSequenceIncludingADropout() async {
        let samples = [
            SensorSample(heartRateBPM: 140, cadenceRPM: 85, timestamp: Date(timeIntervalSince1970: 0)),
            SensorSample(heartRateBPM: nil, cadenceRPM: 85, timestamp: Date(timeIntervalSince1970: 1)),
            SensorSample(heartRateBPM: 142, cadenceRPM: nil, timestamp: Date(timeIntervalSince1970: 2)),
        ]
        let source = ReplaySensorSource(samples: samples)

        var received: [SensorSample] = []
        for await sample in source.sensorUpdates() {
            received.append(sample)
        }

        XCTAssertEqual(received.map(\.heartRateBPM), samples.map(\.heartRateBPM))
        XCTAssertEqual(received.map(\.cadenceRPM), samples.map(\.cadenceRPM))
        XCTAssertNil(received[1].heartRateBPM)
        XCTAssertNil(received[2].cadenceRPM)
    }
}

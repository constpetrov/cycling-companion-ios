import Foundation

@testable import CyclingCompanion

/// Replays a scripted sequence of `SensorSample` values, in order, with no pacing of its own —
/// mirrors `ReplayLocationSource`.
struct ReplaySensorSource: SensorSource {
    let samples: [SensorSample]

    func sensorUpdates() -> AsyncStream<SensorSample> {
        AsyncStream { continuation in
            for sample in samples {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }
}

import Foundation

/// Replays a scripted sequence of `SensorSample` values, in order, with no pacing of its own —
/// mirrors `ReplayLocationSource`. Promoted from the test target into the main target
/// (RULE-26 in spec/rules.md, AC-46); see `ReplayLocationSource` for the full rationale.
#if DEBUG
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
#endif

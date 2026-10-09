import Foundation

/// A single sensor reading (RULE-5 in spec/rules.md). Heart rate and cadence are
/// independently optional — `nil` represents a dropout for that specific metric, flowing
/// through the stream as ordinary data rather than a special "unavailable" event type.
struct SensorSample: Sendable {
    let heartRateBPM: Int?
    let cadenceRPM: Int?
    let timestamp: Date
}

/// Streams sensor readings (RULE-5 in spec/rules.md). No real `CoreBluetooth`/`HealthKit`
/// implementation this milestone — only the protocol and a replay fake for tests.
protocol SensorSource: Sendable {
    func sensorUpdates() -> AsyncStream<SensorSample>
}

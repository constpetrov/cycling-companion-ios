import Foundation

/// A single position update (RULE-4 in spec/rules.md), decoupled from `CLLocation` so fixture
/// replay never needs the real CoreLocation type.
struct LocationFix: Sendable {
    let latitude: Double
    let longitude: Double
    let speedMetersPerSecond: Double
    let timestamp: Date
}

/// Streams position updates (RULE-4 in spec/rules.md). Production uses CoreLocation
/// (task-4.2); tests use a replay fake.
protocol LocationSource: Sendable {
    func locationUpdates() -> AsyncStream<LocationFix>
}

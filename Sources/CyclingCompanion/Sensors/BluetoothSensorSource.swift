import Foundation

/// The ride's `SensorSource` when the rider has remembered sensors (RULE-6, RULE-13 in milestone 12's
/// rules.md). Holding the stream holds the hub for the ride; ending it lets the hub disconnect.
struct BluetoothSensorSource: SensorSource {
    let hub: SensorHub

    func sensorUpdates() -> AsyncStream<SensorSample> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SensorSample.self)
        continuation.onTermination = { [hub] _ in
            Task { @MainActor in hub.detachRide(token) }
        }
        Task { @MainActor [hub] in await hub.attachRide(token, continuation) }
        return stream
    }
}

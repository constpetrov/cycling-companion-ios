import Foundation

/// Whether Bluetooth can be used, as the Sensors screen shows it (AC-13, AC-14).
enum BluetoothAvailability: Equatable, Sendable {
    case unknown
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
}

/// A nearby device found by a scan, with the sensor kinds its advertised services offer.
struct DiscoveredDevice: Equatable, Identifiable, Sendable {
    let identifier: UUID
    let name: String?
    let kinds: Set<SensorKind>

    var id: UUID { identifier }
}

/// What the Bluetooth layer reports. Measurements carry the raw characteristic value; the hub
/// parses them.
enum BluetoothEvent: Sendable {
    case availabilityChanged(BluetoothAvailability)
    case discovered(DiscoveredDevice)
    case connected(UUID)
    case disconnected(UUID)
    /// Heart Rate Measurement (0x2A37).
    case heartRateMeasurement(UUID, Data)
    /// CSC Measurement (0x2A5B).
    case cyclingSpeedAndCadenceMeasurement(UUID, Data)
    /// Cycling Power Measurement (0x2A63).
    case cyclingPowerMeasurement(UUID, Data)
}

/// The CoreBluetooth calls the app needs (RULE-1 in milestone 12's rules.md). `CoreBluetoothCentral`
/// is the real one; `FakeBluetoothCentral` drives tests and UI tests, since the simulator has no
/// Bluetooth. Events reach `eventHandler` one at a time, in order, each awaited before the next.
@MainActor
protocol BluetoothCentral: AnyObject {
    var availability: BluetoothAvailability { get }
    var eventHandler: (@MainActor (BluetoothEvent) async -> Void)? { get set }

    /// Scans for devices advertising the heart rate, cycling speed and cadence or cycling power
    /// service, and nothing else (AC-3, AC-4).
    func startScan()
    func stopScan()
    /// Connects to a known peripheral by identifier. The request stays pending until the device
    /// is in range; an identifier iOS no longer knows is ignored (review hotspot 4).
    func connect(_ identifier: UUID)
    func cancelConnection(_ identifier: UUID)
}

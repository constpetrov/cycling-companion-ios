#if DEBUG
import Foundation

/// A `BluetoothCentral` with no radio, for unit tests and UI tests (RULE-16, RULE-17 in milestone 12's
/// rules.md). It records what the hub asks for; the test delivers events with `emit(_:)`.
@MainActor
final class FakeBluetoothCentral: BluetoothCentral {
    private(set) var availability: BluetoothAvailability
    var eventHandler: (@MainActor (BluetoothEvent) async -> Void)?

    private(set) var isScanning = false
    private(set) var scanStarts = 0
    private(set) var connectCalls: [UUID] = []
    private(set) var cancelCalls: [UUID] = []
    /// Identifiers with a connect request that hasn't been cancelled or completed.
    private(set) var pendingConnects: Set<UUID> = []

    init(availability: BluetoothAvailability = .poweredOn) {
        self.availability = availability
    }

    func startScan() {
        isScanning = true
        scanStarts += 1
    }

    func stopScan() {
        isScanning = false
    }

    func connect(_ identifier: UUID) {
        connectCalls.append(identifier)
        pendingConnects.insert(identifier)
    }

    func cancelConnection(_ identifier: UUID) {
        cancelCalls.append(identifier)
        pendingConnects.remove(identifier)
    }

    /// Delivers one event and waits until the handler has processed it.
    func emit(_ event: BluetoothEvent) async {
        switch event {
        case .availabilityChanged(let availability):
            self.availability = availability
            if availability != .poweredOn {
                isScanning = false
                pendingConnects.removeAll()
            }
        case .connected(let identifier):
            pendingConnects.remove(identifier)
        default:
            break
        }
        await eventHandler?(event)
    }
}
#endif

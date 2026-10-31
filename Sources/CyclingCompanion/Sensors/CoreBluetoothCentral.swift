import CoreBluetooth
import Foundation

/// The real `BluetoothCentral` over `CBCentralManager` (RULE-1, RULE-3, RULE-8 in milestone 12's
/// rules.md). Created only by `SensorHub` when it is first needed, because creating the manager asks
/// for Bluetooth permission. The manager runs on the main queue, so every delegate callback is
/// already on the main actor; the conformances are `@preconcurrency` main-actor ones, which also
/// check that at run time (review hotspot 5). Events go through one stream, handled one at a time in order.
@MainActor
final class CoreBluetoothCentral: NSObject, BluetoothCentral {
    private static let log = Log.logger(category: "Sensors")

    static let heartRateService = CBUUID(string: "180D")
    static let cyclingSpeedAndCadenceService = CBUUID(string: "1816")
    static let cyclingPowerService = CBUUID(string: "1818")
    static let heartRateMeasurement = CBUUID(string: "2A37")
    static let cyclingSpeedAndCadenceMeasurement = CBUUID(string: "2A5B")
    static let cyclingPowerMeasurement = CBUUID(string: "2A63")
    static let supportedServices = [heartRateService, cyclingSpeedAndCadenceService, cyclingPowerService]

    private(set) var availability: BluetoothAvailability = .unknown
    var eventHandler: (@MainActor (BluetoothEvent) async -> Void)?

    private var manager: CBCentralManager!
    /// CoreBluetooth only keeps a connection going while the app holds the peripheral.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private let events: AsyncStream<BluetoothEvent>
    private let eventContinuation: AsyncStream<BluetoothEvent>.Continuation
    /// Runs for the app's lifetime: `AppDependencies` keeps the hub, which keeps this central.
    private var eventTask: Task<Void, Never>?

    override init() {
        (events, eventContinuation) = AsyncStream.makeStream(of: BluetoothEvent.self)
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
        eventTask = Task { [weak self, events] in
            for await event in events {
                await self?.eventHandler?(event)
            }
        }
    }

    func startScan() {
        manager.scanForPeripherals(withServices: Self.supportedServices)
    }

    func stopScan() {
        manager.stopScan()
    }

    func connect(_ identifier: UUID) {
        let peripheral = peripherals[identifier] ?? manager.retrievePeripherals(withIdentifiers: [identifier]).first
        guard let peripheral else {
            // Review hotspot 4: iOS forgot this device (reinstall, Bluetooth reset). It stays remembered.
            Self.log.notice("No known peripheral for a remembered sensor")
            return
        }
        peripherals[identifier] = peripheral
        peripheral.delegate = self
        manager.connect(peripheral)
    }

    func cancelConnection(_ identifier: UUID) {
        guard let peripheral = peripherals.removeValue(forKey: identifier) else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    private func send(_ event: BluetoothEvent) {
        eventContinuation.yield(event)
    }

    private static func availability(for manager: CBCentralManager) -> BluetoothAvailability {
        switch manager.state {
        case .poweredOn: .poweredOn
        case .poweredOff, .resetting: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    private static func kinds(forAdvertisedServices services: [CBUUID]) -> Set<SensorKind> {
        var kinds: Set<SensorKind> = []
        if services.contains(heartRateService) { kinds.insert(.heartRate) }
        if services.contains(cyclingSpeedAndCadenceService) || services.contains(cyclingPowerService) {
            kinds.insert(.cadence)
        }
        return kinds
    }
}

extension CoreBluetoothCentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        availability = Self.availability(for: central)
        if availability != .poweredOn {
            peripherals.removeAll()
        }
        send(.availabilityChanged(availability))
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let identifier = peripheral.identifier
        let name = peripheral.name ?? localName
        send(
            .discovered(
                DiscoveredDevice(
                    identifier: identifier, name: name, kinds: Self.kinds(forAdvertisedServices: services))))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(Self.supportedServices)
        send(.connected(peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?
    ) {
        peripherals[peripheral.identifier] = nil
        send(.disconnected(peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?
    ) {
        peripherals[peripheral.identifier] = nil
        send(.disconnected(peripheral.identifier))
    }
}

extension CoreBluetoothCentral: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(
                [Self.heartRateMeasurement, Self.cyclingSpeedAndCadenceMeasurement, Self.cyclingPowerMeasurement],
                for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?
    ) {
        // Many power meters offer both cycling services. Their crank data may not share counters, so
        // only one feeds the cadence calculator: cycling speed and cadence when the device has it.
        let hasCyclingSpeedAndCadence =
            peripheral.services?.contains { $0.uuid == Self.cyclingSpeedAndCadenceService } ?? false
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.cyclingPowerMeasurement, hasCyclingSpeedAndCadence { continue }
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        let identifier = peripheral.identifier
        let uuid = characteristic.uuid
        switch uuid {
        case Self.heartRateMeasurement: send(.heartRateMeasurement(identifier, value))
        case Self.cyclingSpeedAndCadenceMeasurement: send(.cyclingSpeedAndCadenceMeasurement(identifier, value))
        case Self.cyclingPowerMeasurement: send(.cyclingPowerMeasurement(identifier, value))
        default: break
        }
    }
}

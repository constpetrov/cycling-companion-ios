import Foundation

/// The one owner of Bluetooth sensors (milestone 12's rules.md, RULE-3 to RULE-11). It serves two
/// holders at once:
/// - a ride, which uses the first remembered sensor of each kind to connect and keeps it until it
///   drops (AC-16 to AC-22, AC-26);
/// - the Sensors screen, which connects every remembered sensor in range to show live values and
///   can scan for new ones (AC-3, AC-9, AC-10).
///
/// The Bluetooth central is created on the first `acquire` or `startScan`, never earlier, because
/// creating it asks for permission (RULE-3).
@MainActor
@Observable
final class SensorHub {
    enum Holder: Hashable {
        case ride
        case screen
    }

    struct Reading: Equatable {
        var heartRateBPM: Int?
        var cadenceRPM: Int?
    }

    private static let log = Log.logger(category: "Sensors")
    private static let coastingCheckSeconds: TimeInterval = 1

    private(set) var availability: BluetoothAvailability = .unknown
    /// Devices found by the current scan that offer at least one supported kind.
    private(set) var discovered: [DiscoveredDevice] = []
    /// Latest values from every connected device.
    private(set) var readings: [UUID: Reading] = [:]
    /// The device each kind uses, first come first served.
    private(set) var assigned: [SensorKind: UUID] = [:]
    private(set) var isScanning = false

    private let store: RememberedSensorStore
    private let clock: Clock
    @ObservationIgnored private let makeCentral: @MainActor () -> BluetoothCentral
    @ObservationIgnored private var central: BluetoothCentral?
    @ObservationIgnored private var holders: Set<Holder> = []
    /// Identifiers with a connect request outstanding or completed.
    @ObservationIgnored private var requested: Set<UUID> = []
    @ObservationIgnored private var connected: Set<UUID> = []
    @ObservationIgnored private var calculators: [UUID: CrankCadenceCalculator] = [:]
    @ObservationIgnored private var rideSinks: [UUID: AsyncStream<SensorSample>.Continuation] = [:]
    @ObservationIgnored private var lastPublished = Reading()
    @ObservationIgnored private var coastingTask: Task<Void, Never>?

    init(store: RememberedSensorStore, clock: Clock, makeCentral: @escaping @MainActor () -> BluetoothCentral) {
        self.store = store
        self.clock = clock
        self.makeCentral = makeCentral
    }

    /// The values a ride uses: those of each kind's assigned device.
    var rideReading: Reading {
        Reading(
            heartRateBPM: assigned[.heartRate].flatMap { readings[$0]?.heartRateBPM },
            cadenceRPM: assigned[.cadence].flatMap { readings[$0]?.cadenceRPM })
    }

    func isConnected(_ identifier: UUID) -> Bool {
        readings[identifier] != nil
    }

    // MARK: - Holders

    func acquire(_ holder: Holder) {
        holders.insert(holder)
        ensureCentral()
        reconcile()
        startCoastingChecks()
    }

    /// AC-10: once nothing holds the hub, every connection ends.
    func release(_ holder: Holder) {
        holders.remove(holder)
        if holder == .screen { stopScan() }
        reconcile()
        if holders.isEmpty {
            coastingTask?.cancel()
            coastingTask = nil
        }
    }

    /// Ride side of `BluetoothSensorSource`: every change to the ride's values is yielded to the
    /// stream, both fields each time (RULE-6).
    func attachRide(_ token: UUID, _ continuation: AsyncStream<SensorSample>.Continuation) async {
        rideSinks[token] = continuation
        acquire(.ride)
        let reading = rideReading
        if reading.heartRateBPM != nil || reading.cadenceRPM != nil {
            continuation.yield(
                SensorSample(heartRateBPM: reading.heartRateBPM, cadenceRPM: reading.cadenceRPM, timestamp: await clock.now))
        }
    }

    func detachRide(_ token: UUID) {
        guard rideSinks.removeValue(forKey: token) != nil else { return }
        if rideSinks.isEmpty { release(.ride) }
    }

    // MARK: - Scanning

    func startScan() {
        ensureCentral()
        isScanning = true
        discovered = []
        if availability == .poweredOn { central?.startScan() }
    }

    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        discovered = []
        central?.stopScan()
    }

    // MARK: - Events

    func handle(_ event: BluetoothEvent) async {
        let now = await clock.now
        switch event {
        case .availabilityChanged(let newAvailability):
            availabilityChanged(to: newAvailability)
        case .discovered(let device):
            guard isScanning, !device.kinds.isEmpty else { return }
            if let index = discovered.firstIndex(where: { $0.identifier == device.identifier }) {
                discovered[index] = device
            } else {
                discovered.append(device)
            }
        case .connected(let identifier):
            didConnect(identifier)
        case .disconnected(let identifier):
            didDisconnect(identifier)
        case .heartRateMeasurement(let identifier, let data):
            guard connected.contains(identifier) else { return }
            readings[identifier]?.heartRateBPM = HeartRateMeasurement.bpm(from: data)
        case .cyclingSpeedAndCadenceMeasurement(let identifier, let data):
            ingestCrank(CrankMeasurement.fromCyclingSpeedAndCadence(data), from: identifier, at: now)
        case .cyclingPowerMeasurement(let identifier, let data):
            ingestCrank(CrankMeasurement.fromCyclingPower(data), from: identifier, at: now)
        }
        publish(at: now)
    }

    /// AC-36, AC-37: turns cadence to 0 once the coasting timeout passes with no new crank event.
    /// Run every second by the hub while it is held; tests call it directly.
    func checkCoasting() async {
        let now = await clock.now
        for (identifier, calculator) in calculators where calculator.cadence(at: now) == 0 {
            readings[identifier]?.cadenceRPM = 0
        }
        publish(at: now)
    }

    // MARK: - Private

    private func ensureCentral() {
        guard central == nil else { return }
        let central = makeCentral()
        central.eventHandler = { [weak self] event in await self?.handle(event) }
        self.central = central
        availability = central.availability
    }

    private func availabilityChanged(to newAvailability: BluetoothAvailability) {
        availability = newAvailability
        Self.log.info("Bluetooth availability: \(String(describing: newAvailability), privacy: .public)")
        guard newAvailability == .poweredOn else {
            // RULE-5, AC-24: everything is gone; reconnect once Bluetooth is back.
            requested.removeAll()
            connected.removeAll()
            readings.removeAll()
            assigned.removeAll()
            calculators.removeAll()
            discovered.removeAll()
            return
        }
        if isScanning { central?.startScan() }
        reconcile()
    }

    private func didConnect(_ identifier: UUID) {
        guard requested.contains(identifier) else {
            central?.cancelConnection(identifier)
            return
        }
        connected.insert(identifier)
        readings[identifier] = Reading()
        for kind in store.kinds(for: identifier) where assigned[kind] == nil {
            assigned[kind] = identifier
            Self.log.info("Using a sensor for \(kind.rawValue, privacy: .public)")
        }
        reconcile()
    }

    /// RULE-5, AC-18, AC-19: the kind loses its reading at once, and every remembered sensor of
    /// that kind is asked for again (`reconcile` reads the store afresh, RULE-10).
    private func didDisconnect(_ identifier: UUID) {
        forgetConnection(identifier)
        reconcile()
    }

    private func forgetConnection(_ identifier: UUID) {
        requested.remove(identifier)
        connected.remove(identifier)
        readings[identifier] = nil
        calculators[identifier] = nil
        for (kind, device) in assigned where device == identifier {
            assigned[kind] = nil
            Self.log.info("Lost the sensor for \(kind.rawValue, privacy: .public)")
        }
    }

    private func ingestCrank(_ sample: CrankSample?, from identifier: UUID, at now: Date) {
        guard connected.contains(identifier) else { return }
        var calculator = calculators[identifier] ?? CrankCadenceCalculator()
        readings[identifier]?.cadenceRPM = calculator.ingest(sample, at: now)
        calculators[identifier] = calculator
    }

    /// Which devices should have a connection:
    /// - the screen wants every remembered device;
    /// - a ride wants its assigned devices plus every remembered device of a kind still without one
    ///   (RULE-4);
    /// - with no holder, nothing.
    private var wantedIdentifiers: Set<UUID> {
        var wanted = Set(assigned.values)
        if holders.contains(.screen) {
            wanted.formUnion(store.sensors.map(\.identifier))
        }
        if holders.contains(.ride) {
            for kind in SensorKind.allCases where assigned[kind] == nil {
                wanted.formUnion(store.identifiers(for: kind))
            }
        }
        return holders.isEmpty ? [] : wanted
    }

    /// Issues connects for wanted devices and cancels the rest. Never scans (RULE-4).
    private func reconcile() {
        guard let central, availability == .poweredOn else { return }
        let wanted = wantedIdentifiers
        for identifier in wanted.subtracting(requested) {
            requested.insert(identifier)
            central.connect(identifier)
        }
        for identifier in requested.subtracting(wanted) {
            central.cancelConnection(identifier)
            forgetConnection(identifier)
        }
    }

    private func publish(at now: Date) {
        let reading = rideReading
        guard reading != lastPublished else { return }
        lastPublished = reading
        let sample = SensorSample(heartRateBPM: reading.heartRateBPM, cadenceRPM: reading.cadenceRPM, timestamp: now)
        for sink in rideSinks.values {
            sink.yield(sample)
        }
    }

    private func startCoastingChecks() {
        guard coastingTask == nil else { return }
        coastingTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.coastingCheckSeconds)
                } catch {
                    return
                }
                await self?.checkCoasting()
            }
        }
    }
}

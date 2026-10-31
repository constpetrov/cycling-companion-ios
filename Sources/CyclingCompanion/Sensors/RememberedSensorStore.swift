import Foundation

/// What a sensor measures for the app. A device offering both is remembered once per kind.
enum SensorKind: String, Codable, CaseIterable, Sendable {
    case heartRate
    case cadence

    /// AC-2: shown for a sensor that advertises no name.
    var fallbackName: String {
        switch self {
        case .heartRate: "Heart rate sensor"
        case .cadence: "Cadence sensor"
        }
    }

    var title: String {
        switch self {
        case .heartRate: "Heart rate"
        case .cadence: "Cadence"
        }
    }
}

/// One remembered sensor for one kind (RULE-9 in milestone 12's rules.md). `identifier` is the
/// identifier iOS gives the peripheral on this phone.
struct RememberedSensor: Codable, Hashable, Identifiable, Sendable {
    let identifier: UUID
    let name: String?
    let kind: SensorKind

    var id: String { "\(identifier.uuidString)-\(kind.rawValue)" }
    var displayName: String { name ?? kind.fallbackName }
}

/// The rider's remembered sensors, kept as a JSON array under one `UserDefaults` key
/// (RULE-9, AC-5 to AC-8). On the phone only: never synced or uploaded.
@MainActor
@Observable
final class RememberedSensorStore {
    static let defaultsKey = "rememberedSensors"

    private let defaults: UserDefaults
    private(set) var sensors: [RememberedSensor]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        sensors =
            defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([RememberedSensor].self, from: $0) } ?? []
    }

    var isEmpty: Bool { sensors.isEmpty }

    func hasKind(_ kind: SensorKind) -> Bool {
        sensors.contains { $0.kind == kind }
    }

    func identifiers(for kind: SensorKind) -> Set<UUID> {
        Set(sensors.filter { $0.kind == kind }.map(\.identifier))
    }

    func kinds(for identifier: UUID) -> Set<SensorKind> {
        Set(sensors.filter { $0.identifier == identifier }.map(\.kind))
    }

    /// AC-5, AC-8: one entry per kind the device offers; a kind already remembered for this device
    /// is not added twice. Other sensors of the same kind are kept.
    func remember(_ device: DiscoveredDevice) {
        for kind in SensorKind.allCases where device.kinds.contains(kind) {
            guard !sensors.contains(where: { $0.identifier == device.identifier && $0.kind == kind }) else { continue }
            sensors.append(RememberedSensor(identifier: device.identifier, name: device.name, kind: kind))
        }
        save()
    }

    /// AC-7.
    func forget(_ sensor: RememberedSensor) {
        sensors.removeAll { $0 == sensor }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(sensors), forKey: Self.defaultsKey)
    }
}

import Foundation
import RoutePersistence

/// The six stop types the backend classifies stops into (`StopTagClassifier`), as the rider sees
/// them in Settings. Raw values are the backend's type strings.
enum StopType: String, CaseIterable, Identifiable, Sendable {
    case cafeBakeryRestaurant = "CAFE_BAKERY_RESTAURANT"
    case foodShop = "FOOD_SHOP"
    case water = "WATER"
    case toilets = "TOILETS"
    case restShelter = "REST_SHELTER"
    case bikeRepair = "BIKE_REPAIR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cafeBakeryRestaurant: "Cafés & restaurants"
        case .foodShop: "Food shops"
        case .water: "Drinking water"
        case .toilets: "Toilets"
        case .restShelter: "Rest shelters"
        case .bikeRepair: "Bike repair"
        }
    }

    var detail: String {
        switch self {
        case .cafeBakeryRestaurant: "Cafés, bakeries, restaurants, fast food"
        case .foodShop: "Supermarkets, convenience stores"
        case .water: "Drinking water taps"
        case .toilets: "Public toilets"
        case .restShelter: "Shelters, picnic tables"
        case .bikeRepair: "Bike shops, repair stations"
        }
    }

    var systemImage: String {
        switch self {
        case .cafeBakeryRestaurant: "cup.and.saucer"
        case .foodShop: "cart"
        case .water: "drop"
        case .toilets: "toilet"
        case .restShelter: "house"
        case .bikeRepair: "wrench.and.screwdriver"
        }
    }
}

/// Which stop types the maps draw and the ride suggests. A pure read over `UserDefaults`, so the
/// `RideSession` actor can apply it every cycle without hopping to the main actor.
struct StopTypeFilter: Sendable {
    static let key = "disabledStopTypes"
    /// Every type on; for tests and previews.
    static let allEnabled = StopTypeFilter { [] }

    let disabledTypes: @Sendable () -> Set<String>

    init(disabledTypes: @escaping @Sendable () -> Set<String>) {
        self.disabledTypes = disabledTypes
    }

    init(defaults: UserDefaults) {
        let box = DefaultsBox(defaults: defaults)
        self.init { Set(box.defaults.stringArray(forKey: Self.key) ?? []) }
    }

    /// The stops whose type is on. A type the app doesn't know yet stays on.
    func apply(_ stops: [PersistedPoiInput]) -> [PersistedPoiInput] {
        Self.removing(disabledTypes(), from: stops)
    }

    static func removing(_ disabled: Set<String>, from stops: [PersistedPoiInput]) -> [PersistedPoiInput] {
        guard !disabled.isEmpty else { return stops }
        return stops.filter { !disabled.contains($0.type) }
    }
}

/// `UserDefaults` is documented as thread-safe but isn't marked `Sendable`; this lets the ride's
/// actor read it.
private final class DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }
}

/// The Settings screen's model. Stores the types turned off (not the ones on), so a type added
/// later is shown until the rider turns it off. Everything is on by default.
@MainActor
@Observable
final class StopTypeSettings {
    private(set) var disabledTypes: Set<String>
    let filter: StopTypeFilter
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.filter = StopTypeFilter(defaults: defaults)
        self.disabledTypes = filter.disabledTypes()
    }

    func isEnabled(_ type: StopType) -> Bool {
        !disabledTypes.contains(type.rawValue)
    }

    func setEnabled(_ enabled: Bool, for type: StopType) {
        if enabled {
            disabledTypes.remove(type.rawValue)
        } else {
            disabledTypes.insert(type.rawValue)
        }
        defaults.set(disabledTypes.sorted(), forKey: StopTypeFilter.key)
    }

    var allDisabled: Bool {
        StopType.allCases.allSatisfy { !isEnabled($0) }
    }
}

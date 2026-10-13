import Foundation

/// The `routeId` of the most recently successfully-imported route (RULE-8 in spec/rules.md) —
/// a small pointer stored outside the `RoutePersistence` package. `PersistedRoute` has no
/// timestamp and `RouteStore.fetchAll()` returns a dictionary's values in unstable order, so
/// "most recently imported" isn't derivable from the existing persistence model at all.
/// Injectable `UserDefaults` (not the bare `.standard` singleton) so tests never touch real
/// device state.
struct CurrentRoutePointer {
    private static let key = "currentRouteId"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var routeId: String? {
        get { defaults.string(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

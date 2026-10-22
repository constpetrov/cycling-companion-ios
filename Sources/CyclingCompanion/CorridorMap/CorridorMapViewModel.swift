import Foundation
import RoutePersistence

/// The corridor map's state (RULE-9/RULE-25 in milestone 7's rules.md, AC-102 to AC-113): the route
/// and stops as stored in `RouteStore` (never the import coordinator's in-memory copy), the stop
/// search state, and Retry.
@MainActor
@Observable
final class CorridorMapViewModel {
    let routeId: String
    private let coordinator: CorridorImportCoordinator
    private(set) var route: PersistedRoute?

    init(routeId: String, coordinator: CorridorImportCoordinator) {
        self.routeId = routeId
        self.coordinator = coordinator
    }

    /// AC-113/AC-111: loads the stored route and polls again if it is still building.
    func load() async {
        route = await coordinator.storedRoute(id: routeId)
        await coordinator.ensurePolling(routeId: routeId)
    }

    /// Re-reads the stored route, e.g. once a poll has finished.
    func reload() async {
        route = await coordinator.storedRoute(id: routeId)
    }

    var isPolling: Bool {
        coordinator.isPolling(routeId: routeId)
    }

    /// AC-102 to AC-107.
    var state: CorridorState? {
        route.map { CorridorState(route: $0, isPolling: isPolling) }
    }

    /// AC-108.
    func retry() async {
        let poll = await coordinator.retry(routeId: routeId)
        await reload()
        await poll?.value
        await reload()
    }

    /// AC-114 (RULE-13 of milestone 1): Start Ride is never gated on the stop search.
    var startRideIsEnabled: Bool { true }
}

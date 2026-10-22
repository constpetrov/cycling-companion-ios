import Foundation

/// A screen pushed onto Home's navigation stack (RULE-7 in milestone 7's rules.md). Value routes
/// carry ids only, never live objects.
enum HomeRoute: Hashable {
    case corridorMap(routeId: String)
    #if DEBUG
    case demo
    #endif
}

/// Navigation state only (RULE-2/RULE-7 in milestone 7's rules.md): the stack pushed on top of
/// Home. The ride itself is presented from `RideCoordinator`, never from here, so no navigation
/// change can stop a ride.
@MainActor
@Observable
final class AppRouter {
    var path: [HomeRoute] = []

    /// Shows `route` on top of Home, replacing anything pushed before it.
    func open(_ route: HomeRoute) {
        path = [route]
    }

    func popToHome() {
        path = []
    }
}

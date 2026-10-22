import Foundation

/// Which screen is showing (RULE-9 in spec/rules.md). Navigation only: since milestone 7 the ride
/// lifecycle (active ride, start/finish locks, task cancellation) lives in `RideCoordinator`, so no
/// navigation change can stop a ride (RULE-2 in milestone 7's rules.md).
@MainActor
@Observable
final class AppRouter {
    enum Screen: Equatable {
        case home
        case corridorMap
    }

    private(set) var currentScreen: Screen = .home

    func show(_ screen: Screen) {
        currentScreen = screen
    }
}

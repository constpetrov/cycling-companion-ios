import Foundation
import RoutePersistence

/// The single source of truth for which screen is showing (RULE-9 in spec/rules.md) —
/// constructed once in `CyclingCompanionApp` and injected via SwiftUI's environment; every
/// programmatic screen transition is a mutation of this type, never a view deciding on its
/// own what to show.
@MainActor
@Observable
final class AppRouter {
    /// `.liveRide`'s `LiveRide?` is `nil` only in the brief window between detecting an
    /// unfinished ride (task-2.1) and task-3.2 actually resuming its `RideTracker`/`RideSession`
    /// pair; every other producer of `.liveRide` (Start Ride, task-2.6) always supplies one.
    enum Screen {
        case home
        case corridorMap
        case liveRide(LiveRide?)
    }

    private(set) var currentScreen: Screen = .home
    private var preparingRide = false

    /// Acquired synchronously before Start/Resume/Demo's first await. All three paths
    /// share this router, so rapid taps and a launch-time resume cannot start two loops.
    func beginPreparingRide(resuming: Bool = false) -> Bool {
        guard !preparingRide else { return false }
        if case .liveRide(let ride) = currentScreen, ride != nil || !resuming {
            return false
        }
        preparingRide = true
        return true
    }

    func endPreparingRide() {
        preparingRide = false
    }

    private var finishingRide = false

    /// Acquired synchronously before Finish's first await, so a double tap (each tap spawns
    /// its own `Task`) cannot finalize and upload the same ride twice.
    func beginFinishingRide() -> Bool {
        guard !finishingRide else { return false }
        finishingRide = true
        return true
    }

    func endFinishingRide() {
        finishingRide = false
    }

    /// AC-1/AC-17: checks `RideStore` for an unfinished ride and shows the live ride screen if
    /// one exists, Home otherwise — called once, early in the app's lifecycle, before the
    /// rider can interact with anything. Only decides *which* screen to show; task-3.2 extends
    /// the unfinished-ride path to also resume the actual `RideTracker`/`RideSession` pair.
    func determineInitialScreen(rideStore: RideStore) async {
        if case .liveRide(.some) = currentScreen { return }
        let hasUnfinishedRide = (try? await rideStore.fetchAll().contains { $0.endTime == nil }) ?? false
        if case .liveRide(.some) = currentScreen { return }
        show(hasUnfinishedRide ? .liveRide(nil) : .home)
    }

    func show(_ screen: Screen) {
        if case .liveRide(let oldRide?) = currentScreen {
            if case .liveRide(nil) = screen { return }
            if case .liveRide(let newRide?) = screen, oldRide.tracker === newRide.tracker {
                currentScreen = screen
                return
            }
            oldRide.trackingTask.cancel()
            oldRide.sessionTask.cancel()
        }
        currentScreen = screen
    }
}

extension AppRouter.Screen: Equatable {
    static func == (lhs: AppRouter.Screen, rhs: AppRouter.Screen) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home), (.corridorMap, .corridorMap):
            return true
        case (.liveRide(let lhsRide), .liveRide(let rhsRide)):
            return lhsRide?.tracker === rhsRide?.tracker
        default:
            return false
        }
    }
}

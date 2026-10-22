import Foundation

/// A screen pushed onto Home's navigation stack (RULE-7 in milestone 7's rules.md). Value routes
/// carry ids only, never live objects.
enum HomeRoute: Hashable {
    case corridorMap(routeId: String)
    #if DEBUG
    case demo
    #endif
}

/// A tapped stop notification, waiting to open that stop's sheet (RULE-20 in milestone 7's
/// rules.md). Carries the stop's id only.
struct StopLink: Equatable, Sendable {
    let stopId: Int64

    /// Parses a stop notification's `userInfo` (`Notifier` writes `stopId` as a string).
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["stopId"] as? String, let stopId = Int64(raw) else { return nil }
        self.stopId = stopId
    }

    init(stopId: Int64) {
        self.stopId = stopId
    }
}

/// Navigation state only (RULE-2/RULE-7 in milestone 7's rules.md): the stack pushed on top of
/// Home. The ride itself is presented from `RideCoordinator`, never from here, so no navigation
/// change can stop a ride.
@MainActor
@Observable
final class AppRouter {
    var path: [HomeRoute] = []

    /// A notification tap waiting for the live dashboard to open its stop (AC-71 to AC-75).
    private(set) var pendingStopLink: StopLink?
    /// Set once the launch-time resume has run; before that a tap may belong to a ride that is
    /// about to be resumed (AC-75).
    private(set) var isLaunchResumeFinished = false

    /// AC-71 to AC-76: keeps the link while a ride is active, being prepared or resumed, or before
    /// the launch-time resume has run; drops it when there is no ride to show it on. A tap while
    /// a ride is finishing is dropped too, or it would open on the next ride's dashboard.
    func handle(_ link: StopLink, ridePhase: RideCoordinator.Phase) {
        switch ridePhase {
        case .active, .preparing, .resuming:
            pendingStopLink = link
        case .idle where !isLaunchResumeFinished:
            pendingStopLink = link
        case .idle, .finishing:
            pendingStopLink = nil
        }
    }

    /// Called after the launch-time resume. A link held for a ride that didn't resume is stale.
    func launchResumeFinished(ridePhase: RideCoordinator.Phase) {
        isLaunchResumeFinished = true
        if ridePhase == .idle { pendingStopLink = nil }
    }

    /// The dashboard takes the link once it is showing the active ride.
    func takePendingStopLink() -> StopLink? {
        defer { pendingStopLink = nil }
        return pendingStopLink
    }

    /// Shows `route` on top of Home, replacing anything pushed before it.
    func open(_ route: HomeRoute) {
        path = [route]
    }

    func popToHome() {
        path = []
    }
}

import Foundation
import RoutePersistence

/// Resumes an unfinished ride at launch (RULE-9 in spec/rules.md, AC-17): reconstructs the
/// `RideTracker`/`RideSession` pair from the unfinished checkpoint and activates it through
/// `RideCoordinator`. If there is no unfinished ride, or its route is no longer in `RouteStore`,
/// it leaves the app where it is (Home) and logs why.
@MainActor
struct RideResumer {
    private static let log = Log.logger(category: "RideTracking")

    let rideStore: RideStore
    let routeStore: RouteStore
    let rideCoordinator: RideCoordinator
    let decisionLog: DecisionLog
    let notifier: Notifier
    var advisorClient: AdvisorClient? = nil
    /// The stop types the rider turned off in Settings are never suggested.
    var stopTypeFilter: StopTypeFilter = .allEnabled
    /// Told about an unfinished ride whose route no longer exists (RULE-27 in milestone 7's rules.md).
    var onOrphanedRide: (@MainActor (String) -> Void)? = nil

    func resumeIfNeeded() async {
        guard rideCoordinator.beginPreparingRide(resuming: true) else { return }
        defer { rideCoordinator.endPreparingRide() }
        guard let checkpoint = try? await rideStore.fetchAll().first(where: { $0.endTime == nil }) else {
            Self.log.notice("No unfinished ride to resume")
            return
        }
        guard let route = try? await routeStore.fetch(routeId: checkpoint.routeId) else {
            Self.log.error(
                "Unfinished ride \(checkpoint.id, privacy: .public) references a missing route \(checkpoint.routeId, privacy: .public) — staying on Home"
            )
            onOrphanedRide?(checkpoint.id)
            return
        }
        let (tracker, session) = await makeTrackerAndSession(
            rideId: checkpoint.id, routeId: checkpoint.routeId, startTime: checkpoint.startTime, route: route,
            locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
            rideStore: rideStore, routeStore: routeStore, decisionLog: decisionLog, notifier: notifier,
            advisorClient: advisorClient, stopTypeFilter: stopTypeFilter)
        try? await tracker.resumeIfNeeded(from: rideStore)
        if let suggestionState = checkpoint.suggestionState {
            await session.restoreLedger(SuggestionLedger(persisted: suggestionState))
        }

        Self.log.info("Resumed ride \(checkpoint.id, privacy: .public)")
        rideCoordinator.activate(startLiveRideTasks(tracker: tracker, session: session))
    }
}

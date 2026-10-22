import Foundation
import RoutePersistence

/// Resumes an unfinished ride at launch (RULE-9 in spec/rules.md, AC-17) — extends
/// `AppRouter.determineInitialScreen`'s detection (task-2.1) by actually reconstructing the
/// `RideTracker`/`RideSession` pair, matching `AppDelegate`'s existing `resumeIfNeeded` path
/// (Milestone 2), and upgrading the screen to carry it. If reconstruction fails for any reason
/// (missing/corrupted checkpoint, route no longer in `RouteStore`), falls back to `.home`
/// rather than leaving the screen stuck on `.liveRide(nil)`'s placeholder spinner forever —
/// same "never a stuck loading state" rule `HomeViewModel.refresh()` already follows.
@MainActor
struct RideResumer {
    private static let log = Log.logger(category: "RideTracking")

    let rideStore: RideStore
    let routeStore: RouteStore
    let appRouter: AppRouter
    let decisionLog: DecisionLog
    let notifier: Notifier
    var advisorClient: AdvisorClient? = nil

    func resumeIfNeeded() async {
        guard appRouter.beginPreparingRide(resuming: true) else { return }
        defer { appRouter.endPreparingRide() }
        await appRouter.determineInitialScreen(rideStore: rideStore)
        guard case .liveRide(nil) = appRouter.currentScreen else {
            return
        }
        guard let checkpoint = try? await rideStore.fetchAll().first(where: { $0.endTime == nil }) else {
            Self.log.notice("No unfinished ride to resume — falling back to Home")
            appRouter.show(.home)
            return
        }
        guard let route = try? await routeStore.fetch(routeId: checkpoint.routeId) else {
            Self.log.error(
                "Unfinished ride \(checkpoint.id, privacy: .public) references a missing route \(checkpoint.routeId, privacy: .public) — falling back to Home"
            )
            appRouter.show(.home)
            return
        }
        let (tracker, session) = await makeTrackerAndSession(
            rideId: checkpoint.id, routeId: checkpoint.routeId, startTime: checkpoint.startTime, route: route,
            locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
            rideStore: rideStore, routeStore: routeStore, decisionLog: decisionLog, notifier: notifier,
            advisorClient: advisorClient)
        try? await tracker.resumeIfNeeded(from: rideStore)

        Self.log.info("Resumed ride \(checkpoint.id, privacy: .public)")
        appRouter.show(.liveRide(startLiveRideTasks(tracker: tracker, session: session)))
    }
}

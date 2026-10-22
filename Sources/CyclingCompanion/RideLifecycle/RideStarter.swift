import Foundation
import RoutePersistence

/// Constructs a real `RideTracker`/`RideSession` pair for the current route and navigates to
/// the live ride screen (RULE-9 in spec/rules.md, AC-10/AC-11) — regardless of whether
/// corridor POIs have finished building (RULE-13's "never disabled" extends here too: nothing
/// blocks Start Ride on settle status). A no-op if there's no current route to ride against.
@MainActor
struct RideStarter {
    let routeStore: RouteStore
    let pointer: CurrentRoutePointer
    let appRouter: AppRouter
    let decisionLog: DecisionLog
    let notifier: Notifier
    var advisorClient: AdvisorClient? = nil

    func startRide() async {
        guard appRouter.beginPreparingRide() else { return }
        defer { appRouter.endPreparingRide() }
        guard let routeId = pointer.routeId, let route = try? await routeStore.fetch(routeId: routeId) else {
            return
        }
        guard let rideStoreURL = try? RideStore.defaultFileURL() else {
            return
        }
        let rideStore = RideStore(fileURL: rideStoreURL)
        let (tracker, session) = await makeTrackerAndSession(
            rideId: UUID().uuidString, routeId: routeId, startTime: Date(), route: route,
            locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
            rideStore: rideStore, routeStore: routeStore, decisionLog: decisionLog, notifier: notifier,
            advisorClient: advisorClient)

        appRouter.show(.liveRide(startLiveRideTasks(tracker: tracker, session: session)))
    }
}

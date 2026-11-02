import Foundation
import RoutePersistence

/// Constructs a real `RideTracker`/`RideSession` pair for the current route and navigates to
/// the live ride screen (RULE-9 in spec/rules.md, AC-10/AC-11) — regardless of whether
/// corridor POIs have finished building (RULE-13's "never disabled" extends here too: nothing
/// blocks Start Ride on settle status). A no-op if there's no current route to ride against.
@MainActor
struct RideStarter {
    let routeStore: RouteStore
    let rideStore: RideStore
    let pointer: CurrentRoutePointer
    let rideCoordinator: RideCoordinator
    let decisionLog: DecisionLog
    let notifier: Notifier
    var advisorClient: AdvisorClient? = nil
    /// The stop types the rider turned off in Settings are never suggested.
    var stopTypeFilter: StopTypeFilter = .allEnabled
    /// Milestone 12 (RULE-13): Bluetooth sensors when the rider has remembered any, otherwise none.
    var makeSensorSource: @MainActor () -> SensorSource = { NoSensorSource() }

    func startRide() async {
        guard rideCoordinator.beginPreparingRide() else { return }
        defer { rideCoordinator.endPreparingRide() }
        guard let routeId = pointer.routeId, let route = try? await routeStore.fetch(routeId: routeId) else {
            return
        }
        let (tracker, session) = await makeTrackerAndSession(
            rideId: UUID().uuidString, routeId: routeId, startTime: Date(), route: route,
            locationSource: CoreLocationSource(), sensorSource: makeSensorSource(), clock: SystemClock(),
            rideStore: rideStore, routeStore: routeStore, decisionLog: decisionLog, notifier: notifier,
            advisorClient: advisorClient, stopTypeFilter: stopTypeFilter)

        rideCoordinator.activate(startLiveRideTasks(tracker: tracker, session: session))
    }
}

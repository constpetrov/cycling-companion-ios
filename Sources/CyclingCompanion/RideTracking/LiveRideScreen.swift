import Foundation
import RoutePersistence
import SwiftUI

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

    func startRide() async {
        guard let routeId = pointer.routeId, let route = try? await routeStore.fetch(routeId: routeId) else {
            return
        }
        guard let rideStoreURL = try? RideStore.defaultFileURL() else {
            return
        }
        let resampledPoints = route.points.map {
            ResampledPoint(
                latitude: $0.latitude, longitude: $0.longitude, elevationMeters: $0.elevationMeters,
                cumulativeDistanceMeters: $0.cumulativeDistanceMeters)
        }
        let rideStore = RideStore(fileURL: rideStoreURL)
        let tracker = RideTracker(
            rideId: UUID().uuidString, routeId: routeId, startTime: Date(), route: resampledPoints,
            locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
            rideStore: rideStore)
        let engine = FeatureEngine(rideTracker: tracker, route: resampledPoints, clock: SystemClock())
        let session = RideSession(
            rideTracker: tracker, featureEngine: engine, clock: SystemClock(), routeId: routeId,
            routeStore: routeStore, decisionLog: decisionLog, notifier: notifier)

        // Both loops are unbounded for real sources/a real ride — fired as background Tasks so
        // `startRide()` itself returns and navigation happens immediately.
        Task { await tracker.start() }
        Task { try? await session.run() }

        appRouter.show(.liveRide(tracker))
    }
}

/// The live ride screen (RULE-9/RULE-16 in spec/rules.md, AC-10/AC-11) — reuses
/// `RideProgressView` to render an already-constructed, already-running `RideTracker`. `nil`
/// only in the brief window before task-3.2's launch-time resume has reconstructed a tracker
/// for an unfinished ride.
struct LiveRideScreen: View {
    let rideTracker: RideTracker?

    var body: some View {
        if let rideTracker {
            RideProgressView(rideTracker: rideTracker)
        } else {
            ProgressView()
        }
    }
}

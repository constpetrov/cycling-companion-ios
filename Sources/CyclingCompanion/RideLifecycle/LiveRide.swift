import Foundation
import RoutePersistence

/// A live ride's running state (RULE-9 in spec/rules.md) — bundles the `RideTracker`
/// `LiveRideScreen`/Finish Ride read from, the `RideSession` the debug-only force-check
/// control (task-4.4) needs a live reference to, and the two background `Task`s that must be
/// cancelled to actually stop tracking. `Task.cancel()` on `trackingTask` propagates into
/// `locationSource.locationUpdates()`'s `for await` loop, which is what makes
/// `CoreLocationSource`'s `AsyncStream.Continuation.onTermination` fire and call
/// `CLLocationManager.stopUpdatingLocation()` — cancellation isn't just bookkeeping here, it's
/// the only thing that actually stops GPS.
struct LiveRide {
    let tracker: RideTracker
    let session: RideSession
    let trackingTask: Task<Void, Never>
    let sessionTask: Task<Void, Never>
}

/// Shared by `RideStarter`, `RideResumer`, and (Demo Mode) `DemoRideStarter`: builds the
/// `RideTracker`/`FeatureEngine`/`RideSession` trio against `route`'s geometry. Takes its
/// sources and clock as parameters — never names `DemoModeReplayDriver` itself (RULE-15: that
/// type only exists inside `#if DEBUG`, so this always-compiled function must stay generic
/// over `LocationSource`/`SensorSource`/`Clock` to let a `#if DEBUG`-gated caller pass one in).
@MainActor
func makeTrackerAndSession(
    rideId: String, routeId: String, startTime: Date, route: PersistedRoute, locationSource: LocationSource,
    sensorSource: SensorSource, clock: Clock, rideStore: RideStore, routeStore: RouteStore,
    decisionLog: DecisionLog, notifier: Notifier, advisorClient: AdvisorClient? = nil
) async -> (tracker: RideTracker, session: RideSession) {
    let resampledPoints = route.points.map {
        ResampledPoint(
            latitude: $0.latitude, longitude: $0.longitude, elevationMeters: $0.elevationMeters,
            cumulativeDistanceMeters: $0.cumulativeDistanceMeters)
    }
    let tracker = RideTracker(
        rideId: rideId, routeId: routeId, startTime: startTime, route: resampledPoints,
        locationSource: locationSource, sensorSource: sensorSource, clock: clock, rideStore: rideStore)
    // RULE-2: computed once here, not re-read on every FeatureEngine tick.
    let baselines = await BaselineCalculator.compute(from: rideStore)
    let engine = FeatureEngine(rideTracker: tracker, route: resampledPoints, clock: clock, baselines: baselines)
    let session = RideSession(
        rideTracker: tracker, featureEngine: engine, clock: clock, routeId: routeId, routeStore: routeStore,
        decisionLog: decisionLog, notifier: notifier, advisorClient: advisorClient)
    return (tracker, session)
}

/// Fires both of `LiveRide`'s background `Task`s — unbounded for real sources, so this returns
/// immediately rather than ever awaiting either.
@MainActor
func startLiveRideTasks(tracker: RideTracker, session: RideSession) -> LiveRide {
    let trackingTask = Task { await tracker.start() }
    let sessionTask = Task<Void, Never> {
        _ = try? await session.run()
    }
    return LiveRide(tracker: tracker, session: session, trackingTask: trackingTask, sessionTask: sessionTask)
}

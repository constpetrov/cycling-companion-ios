import Foundation
import RoutePersistence
import SwiftUI

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
    decisionLog: DecisionLog, notifier: Notifier
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
        decisionLog: decisionLog, notifier: notifier)
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
        let rideStore = RideStore(fileURL: rideStoreURL)
        let (tracker, session) = await makeTrackerAndSession(
            rideId: UUID().uuidString, routeId: routeId, startTime: Date(), route: route,
            locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
            rideStore: rideStore, routeStore: routeStore, decisionLog: decisionLog, notifier: notifier)

        appRouter.show(.liveRide(startLiveRideTasks(tracker: tracker, session: session)))
    }
}

/// Resumes an unfinished ride at launch (RULE-9 in spec/rules.md, AC-17) — extends
/// `AppRouter.determineInitialScreen`'s detection (task-2.1) by actually reconstructing the
/// `RideTracker`/`RideSession` pair, matching `AppDelegate`'s existing `resumeIfNeeded` path
/// (Milestone 2), and upgrading the screen to carry it. If reconstruction fails for any reason
/// (missing/corrupted checkpoint, route no longer in `RouteStore`), falls back to `.home`
/// rather than leaving the screen stuck on `.liveRide(nil)`'s placeholder spinner forever —
/// same "never a stuck loading state" rule `HomeViewModel.refresh()` already follows.
@MainActor
struct RideResumer {
    let rideStore: RideStore
    let routeStore: RouteStore
    let appRouter: AppRouter
    let decisionLog: DecisionLog
    let notifier: Notifier

    func resumeIfNeeded() async {
        await appRouter.determineInitialScreen(rideStore: rideStore)
        guard case .liveRide(nil) = appRouter.currentScreen else {
            return
        }
        guard let checkpoint = try? await rideStore.fetchAll().first(where: { $0.endTime == nil }) else {
            appRouter.show(.home)
            return
        }
        guard let route = try? await routeStore.fetch(routeId: checkpoint.routeId) else {
            appRouter.show(.home)
            return
        }
        let (tracker, session) = await makeTrackerAndSession(
            rideId: checkpoint.id, routeId: checkpoint.routeId, startTime: checkpoint.startTime, route: route,
            locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
            rideStore: rideStore, routeStore: routeStore, decisionLog: decisionLog, notifier: notifier)
        try? await tracker.resumeIfNeeded(from: rideStore)

        appRouter.show(.liveRide(startLiveRideTasks(tracker: tracker, session: session)))
    }
}

/// Stops a live ride and finalizes it (RULE-9 in spec/rules.md, AC-16): cancels both of
/// `LiveRide`'s background `Task`s — which is what actually stops `CoreLocationSource` (see
/// `LiveRide`'s own doc comment) and `RideSession`'s loop — then writes the final
/// `PersistedRide` through `RideRecorder` and navigates back to Home.
@MainActor
struct RideFinisher {
    let rideRecorder: RideRecorder
    let appRouter: AppRouter

    /// `endTime` is the one deliberate exception to this project's "never `Date()` directly"
    /// convention: every other use of that rule is about *computing a ride-data-derived
    /// feature* without reading the live clock; this is the instant the rider tapped Finish
    /// Ride, which has no track-derived equivalent to fall back to.
    func finishRide(_ liveRide: LiveRide) async {
        liveRide.trackingTask.cancel()
        liveRide.sessionTask.cancel()

        let tracker = liveRide.tracker
        try? await rideRecorder.finalize(
            rideId: tracker.rideId, routeId: tracker.routeId, startTime: tracker.startTime, endTime: Date(),
            totalDistanceMeters: tracker.distanceAlongRouteMeters, totalMovingTimeSeconds: tracker.movingTimeSeconds,
            track: tracker.track)

        appRouter.show(.home)
    }
}

/// The live ride screen (RULE-9/RULE-16 in spec/rules.md, AC-10/AC-11/AC-16) — reuses
/// `RideProgressView` to render an already-constructed, already-running `RideTracker`, plus a
/// Finish Ride button. `nil` only in the brief window before `RideResumer` has reconstructed a
/// tracker for an unfinished ride.
struct LiveRideScreen: View {
    let rideTracker: RideTracker?
    let onFinishRide: () -> Void

    var body: some View {
        if let rideTracker {
            VStack {
                RideProgressView(rideTracker: rideTracker)
                Button("Finish Ride", action: onFinishRide)
            }
        } else {
            ProgressView()
        }
    }
}

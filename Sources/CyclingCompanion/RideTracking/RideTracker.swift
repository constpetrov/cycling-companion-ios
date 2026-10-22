import Foundation
import Observation
import RoutePersistence

/// Tracks a ride live against its planned route (RULE-3 in spec/rules.md). `@MainActor
/// @Observable` — the progress screen binds to it directly, the first component in this
/// project needing continuously-updating SwiftUI state (plain actors, the
/// `CorridorPollingService` precedent, have no reactive-observation story).
///
/// Map-matches each GPS fix against the route (task-2.2): `distanceAlongRouteMeters` only
/// advances while the fix projects within `corridorToleranceMeters` of the route (AC-2/3/6);
/// an off-route fix leaves it unchanged but is still appended to `track` (AC-4/5), so the
/// raw record stays complete even through an off-route excursion. Moving-time/ETA
/// (task-2.3): elapsed time between consecutive fixes comes from `LocationFix.timestamp`
/// (data the injected `LocationSource` supplies, per RULE-15), not `clock` — `Clock` only
/// exposes `sleep(for:)` (the `CorridorPollingService` precedent), which fits a polling loop,
/// not this push-based consumer; `clock` stays a constructor dependency for later
/// delay-based needs (e.g. dropout flagging). Checkpoints itself to `rideStore` after every
/// accepted location update (RULE-12 in spec/rules.md), writing a `PersistedRide` with
/// `endTime` left unset; the final write that sets `endTime` is `RideRecorder`'s alone
/// (RULE-11) — this class never performs it.
@MainActor
@Observable
final class RideTracker {
    /// AC-2/AC-3: a fix projecting at exactly this distance still counts as in-corridor. The one
    /// source of truth for "on route", also read by the dashboard's off-route badge (RULE-12 in
    /// milestone 7's rules.md).
    nonisolated static let corridorToleranceMeters: Double = 50
    /// AC-9/AC-10/AC-11: strictly above this counts as moving; at or below does not.
    private static let movingThresholdMetersPerSecond: Double = 0.5
    /// AC-7/AC-8: below this much accumulated moving time, pace is too noisy to report an
    /// ETA; spec.md leaves the exact value to this task. 30s is comfortably past the first
    /// few noisy GPS fixes while still reporting an ETA early in a ride.
    private static let minimumMovingTimeSecondsForETA: Double = 30

    private(set) var latestFix: LocationFix?
    /// How far the latest fix was from the route (`nil` before the first fix). Above
    /// `corridorToleranceMeters` means off route.
    private(set) var latestOffRouteMeters: Double?
    /// When the latest fix arrived, on `clock` (not the fix's own timestamp), so the dashboard can
    /// measure a GPS gap against the same clock (RULE-12 in milestone 7's rules.md).
    private(set) var lastFixAt: Date?
    private(set) var currentHeartRateBPM: Int?
    private(set) var currentCadenceRPM: Int?
    private(set) var distanceAlongRouteMeters: Double = 0
    private(set) var movingTimeSeconds: Double = 0
    private(set) var etaSeconds: Double?
    private(set) var track: [PersistedRideSample] = []

    /// AC-14: the progress screen's "distance remaining" needs the route's total; exposed here
    /// rather than making the view read `route` directly, since `route` stays private.
    var totalRouteDistanceMeters: Double {
        route.last?.cumulativeDistanceMeters ?? 0
    }

    /// Not `private` (Milestone 4, RULE-9/AC-16): `RideRecorder.finalize` needs these to
    /// identify which ride it's closing out — `LiveRideScreen`'s Finish Ride reads them
    /// directly rather than threading a second copy through `AppRouter`. Still `let`: nothing
    /// outside this type ever needs to change them.
    let rideId: String
    let routeId: String
    let startTime: Date
    private let route: [ResampledPoint]
    private let locationSource: LocationSource
    private let sensorSource: SensorSource
    /// The ride's clock (wall time for a real ride, scaled ride time for Demo Mode); the dashboard
    /// measures GPS gaps on the same clock (RULE-12 in milestone 7's rules.md).
    let clock: Clock
    private let rideStore: RideStore
    private var previousFixTimestamp: Date?
    private var lastMatchedFix: LocationFix?

    init(
        rideId: String, routeId: String, startTime: Date, route: [ResampledPoint], locationSource: LocationSource,
        sensorSource: SensorSource, clock: Clock, rideStore: RideStore
    ) {
        self.rideId = rideId
        self.routeId = routeId
        self.startTime = startTime
        self.route = route
        self.locationSource = locationSource
        self.sensorSource = sensorSource
        self.clock = clock
        self.rideStore = rideStore
    }

    /// AC-20, RULE-13: looks up `store`'s single unfinished checkpoint — a `PersistedRide`
    /// with no `endTime` — and re-hydrates `distanceAlongRouteMeters`/`movingTimeSeconds`/
    /// `track` from it; a no-op if none is found. There's no UI to start a second ride while
    /// one is already active, so at most one unfinished checkpoint can ever exist and no
    /// selection logic is needed. Deliberately leaves `previousFixTimestamp` as `nil`: treating
    /// the first post-resume fix as if it had no predecessor avoids inventing a bogus moving-
    /// time interval spanning however long the app was actually terminated for.
    func resumeIfNeeded(from store: RideStore) async throws {
        guard let checkpoint = try await store.fetchAll().first(where: {
            $0.endTime == nil && (rideId.isEmpty || $0.id == rideId)
        }) else {
            return
        }
        distanceAlongRouteMeters = checkpoint.totalDistanceMeters
        movingTimeSeconds = checkpoint.totalMovingTimeSeconds
        track = checkpoint.track
        if let last = track.last {
            lastMatchedFix = LocationFix(
                latitude: last.latitude, longitude: last.longitude,
                speedMetersPerSecond: last.speedMetersPerSecond, timestamp: last.timestamp)
        }
        etaSeconds = computeETA()
    }

    /// AC-1: begins consuming position updates; also consumes sensor updates, publishing each
    /// source's latest reading as it arrives. Awaits full consumption of both streams — for
    /// the fakes used in tests, that means until the scripted sequence is exhausted; the
    /// production `LocationSource`/`SensorSource` streams simply don't finish during a ride.
    func start() async {
        async let locationConsumption: Void = consumeLocationUpdates()
        async let sensorConsumption: Void = consumeSensorUpdates()
        _ = await (locationConsumption, sensorConsumption)
    }

    /// AC-2/AC-3/AC-4/AC-6: map-matches the fix against `route`; only advances
    /// `distanceAlongRouteMeters`/`etaSeconds` while within the corridor tolerance, so an
    /// off-route fix (AC-4) nor resuming from one (AC-6) needs special-case handling — the
    /// gate alone produces both behaviors. AC-5: every fix is recorded to `track` regardless.
    /// AC-9/AC-10/AC-11: moving-time accrual is independent of the corridor gate — spec.md's
    /// off-route freeze applies to progress/ETA, not to whether the rider is moving.
    private func consumeLocationUpdates() async {
        for await fix in locationSource.locationUpdates() {
            latestFix = fix
            lastFixAt = await clock.now
            accumulateMovingTime(upTo: fix)

            let closestPoint = GeoMath.closestPointOnRoute(
                latitude: fix.latitude, longitude: fix.longitude, route: route,
                progressRange: reachableProgress(for: fix))
            latestOffRouteMeters = closestPoint.offRouteMeters
            if closestPoint.offRouteMeters <= Self.corridorToleranceMeters {
                distanceAlongRouteMeters = closestPoint.distanceAlongRouteMeters
                lastMatchedFix = fix
                etaSeconds = computeETA()
            }

            track.append(
                PersistedRideSample(
                    latitude: fix.latitude, longitude: fix.longitude, speedMetersPerSecond: fix.speedMetersPerSecond,
                    heartRateBPM: currentHeartRateBPM, cadenceRPM: currentCadenceRPM, timestamp: fix.timestamp))

            await checkpoint()
        }
    }

    /// Uses both elapsed GPS time and displacement, allowing sparse fixes and real
    /// backtracking. 25 m/s is a generous cycling bound; 100 m absorbs GPS noise. The
    /// displacement allowance accommodates bends and resampled route distances.
    private func reachableProgress(for fix: LocationFix) -> ClosedRange<Double>? {
        guard let previous = lastMatchedFix else { return nil }
        let elapsed = max(0, fix.timestamp.timeIntervalSince(previous.timestamp))
        let displacement = GeoMath.haversineDistanceMeters(
            TrackPoint(latitude: previous.latitude, longitude: previous.longitude, elevationMeters: nil),
            TrackPoint(latitude: fix.latitude, longitude: fix.longitude, elevationMeters: nil))
        let allowance = max(100, max(elapsed * 25, displacement * 3))
        let progress = min(totalRouteDistanceMeters, max(0, distanceAlongRouteMeters))
        return max(0, progress - allowance)...min(totalRouteDistanceMeters, progress + allowance)
    }

    /// RULE-12: persists the accumulated state so far with `endTime` left unset. A failed
    /// write is swallowed rather than propagated — per RULE-11's reasoning, each checkpoint is
    /// low-stakes and immediately superseded by the next one, so there's nothing a caller
    /// should do differently if one write fails.
    private func checkpoint() async {
        let snapshot = PersistedRide(
            id: rideId, routeId: routeId, startTime: startTime, endTime: nil,
            totalDistanceMeters: distanceAlongRouteMeters, totalMovingTimeSeconds: movingTimeSeconds, track: track)
        try? await rideStore.persist(snapshot)
    }

    /// AC-9/AC-10/AC-11: the interval since the previous fix counts as moving time only when
    /// this fix's instantaneous speed is strictly above the moving threshold.
    private func accumulateMovingTime(upTo fix: LocationFix) {
        defer { previousFixTimestamp = fix.timestamp }
        guard let previous = previousFixTimestamp else { return }

        let elapsedSeconds = fix.timestamp.timeIntervalSince(previous)
        if elapsedSeconds > 0, fix.speedMetersPerSecond > Self.movingThresholdMetersPerSecond {
            movingTimeSeconds += elapsedSeconds
        }
    }

    /// AC-7/AC-8: no ETA below the minimum moving time (also guards the division below
    /// against a near-zero distance); otherwise remaining distance ÷ average pace so far.
    private func computeETA() -> Double? {
        guard movingTimeSeconds >= Self.minimumMovingTimeSecondsForETA, distanceAlongRouteMeters > 0 else {
            return nil
        }
        let remainingMeters = max(totalRouteDistanceMeters - distanceAlongRouteMeters, 0)
        let secondsPerMeter = movingTimeSeconds / distanceAlongRouteMeters
        return remainingMeters * secondsPerMeter
    }

    /// AC-12/AC-13: always overwrites with the new sample's fields, `nil` or not — never
    /// leaves a dropped-out metric showing a stale prior reading.
    private func consumeSensorUpdates() async {
        for await sample in sensorSource.sensorUpdates() {
            currentHeartRateBPM = sample.heartRateBPM
            currentCadenceRPM = sample.cadenceRPM
        }
    }
}

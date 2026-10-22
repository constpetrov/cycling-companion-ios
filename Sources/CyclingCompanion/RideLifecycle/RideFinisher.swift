import Foundation
import RoutePersistence

/// Stops a live ride and finalizes it (RULE-9 in spec/rules.md, AC-16): cancels both of
/// `LiveRide`'s background `Task`s — which is what actually stops `CoreLocationSource` (see
/// `LiveRide`'s own doc comment) and `RideSession`'s loop — then writes the final
/// `PersistedRide` through `RideRecorder` and navigates back to Home.
@MainActor
struct RideFinisher {
    private static let log = Log.logger(category: "RideTracking")

    let rideRecorder: RideRecorder
    let appRouter: AppRouter
    let decisionLog: DecisionLog
    let rideStore: RideStore
    let rideIngestClient: RideIngestClient
    let pendingUploadQueue: PendingRideUploadQueue

    /// `endTime` is the one deliberate exception to this project's "never `Date()` directly"
    /// convention: every other use of that rule is about *computing a ride-data-derived
    /// feature* without reading the live clock; this is the instant the rider tapped Finish
    /// Ride, which has no track-derived equivalent to fall back to.
    ///
    /// Navigates Home as soon as the ride is finalized locally, before the upload: the upload
    /// can take as long as the network allows, and the rider shouldn't be left on a frozen live
    /// screen meanwhile. A failed finalize leaves the unfinished checkpoint in `RideStore`, so
    /// the next launch resumes the ride rather than losing it.
    func finishRide(_ liveRide: LiveRide) async {
        guard appRouter.beginFinishingRide() else { return }
        defer { appRouter.endFinishingRide() }

        liveRide.trackingTask.cancel()
        liveRide.sessionTask.cancel()

        let tracker = liveRide.tracker
        let endTime = Date()
        do {
            try await rideRecorder.finalize(
                rideId: tracker.rideId, routeId: tracker.routeId, startTime: tracker.startTime, endTime: endTime,
                totalDistanceMeters: tracker.distanceAlongRouteMeters,
                totalMovingTimeSeconds: tracker.movingTimeSeconds, track: tracker.track)
        } catch {
            Self.log.error(
                "Finalizing ride \(tracker.rideId, privacy: .public) failed: \(String(describing: error), privacy: .public) — it will resume on next launch")
        }

        appRouter.show(.home)

        await uploadRide(tracker: tracker, session: liveRide.session, endTime: endTime)
    }

    /// RULE-5/RULE-7/RULE-8/RULE-10/RULE-11 in spec/rules.md (AC-4 through AC-13): computes
    /// `stopsTaken`/`outcome` on-device, uploads immediately, and queues for retry at the next
    /// launch on any failure — never blocks `finishRide` on the network.
    private func uploadRide(tracker: RideTracker, session: RideSession, endTime: Date) async {
        let historicalRides = (try? await rideStore.fetchAll()) ?? []
        let stopsTaken = RideOutcomeCalculator.stopsTaken(
            postedNotifications: decisionLog.postedNotifications, track: tracker.track)
        let outcome = RideOutcomeCalculator.outcome(
            thisRideDistanceMeters: tracker.distanceAlongRouteMeters, historicalRides: historicalRides)
        let snapshots = await session.featureSnapshots()

        let payload = RideIngestRequestPayload(
            routeId: tracker.routeId, startTime: tracker.startTime, endTime: endTime,
            totalDistanceMeters: tracker.distanceAlongRouteMeters, totalMovingTimeSeconds: tracker.movingTimeSeconds,
            stopsTaken: stopsTaken, outcome: outcome.rawValue, featureSnapshots: snapshots.map(FeatureSnapshotPayload.init))

        let succeeded = await rideIngestClient.ingest(payload)
        if !succeeded {
            try? await pendingUploadQueue.enqueue(payload)
        }
    }
}

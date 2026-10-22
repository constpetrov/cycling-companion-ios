import Foundation
import RoutePersistence

/// Stops a live ride and finalizes it (RULE-9 in spec/rules.md, AC-16): cancels both of
/// `LiveRide`'s background `Task`s — which is what actually stops `CoreLocationSource` (see
/// `LiveRide`'s own doc comment) and `RideSession`'s loop — then writes the final
/// `PersistedRide` through `RideRecorder` and hands the outcome to `RideCoordinator`.
@MainActor
struct RideFinisher {
    private static let log = Log.logger(category: "RideTracking")

    let rideRecorder: RideFinalizing
    let rideCoordinator: RideCoordinator
    let decisionLog: DecisionLog
    let rideStore: RideStore
    let rideIngestClient: RideIngestClient
    let pendingUploadQueue: PendingRideUploadQueue

    /// `endTime` is the one deliberate exception to this project's "never `Date()` directly"
    /// convention: every other use of that rule is about *computing a ride-data-derived
    /// feature* without reading the live clock; this is the instant the rider tapped Finish
    /// Ride, which has no track-derived equivalent to fall back to.
    ///
    /// Hands the outcome to the coordinator as soon as the ride is finalized locally, before the
    /// upload: the upload can take as long as the network allows, and the rider shouldn't be left
    /// on a frozen live screen meanwhile. AC-84: a failed finalize skips the upload and leaves the
    /// unfinished checkpoint in `RideStore`, so the next launch resumes the ride rather than losing
    /// it (or uploading a ride the phone itself doesn't have).
    @discardableResult
    func finishRide(_ liveRide: LiveRide) async -> FinishOutcome? {
        guard rideCoordinator.beginFinishingRide() else { return nil }
        defer { rideCoordinator.endFinishingRide() }

        rideCoordinator.end(liveRide)

        let tracker = liveRide.tracker
        let endTime = Date()
        let outcome: FinishOutcome
        do {
            let saved = try await rideRecorder.finalize(
                rideId: tracker.rideId, routeId: tracker.routeId, startTime: tracker.startTime, endTime: endTime,
                totalDistanceMeters: tracker.distanceAlongRouteMeters,
                totalMovingTimeSeconds: tracker.movingTimeSeconds, track: tracker.track)
            outcome = .saved(saved)
        } catch {
            outcome = .notSaved
            Self.log.error(
                "Finalizing ride \(tracker.rideId, privacy: .public) failed: \(String(describing: error), privacy: .public) — it will resume on next launch")
        }

        rideCoordinator.presentSummary(outcome)

        if case .saved = outcome {
            await uploadRide(tracker: tracker, session: liveRide.session, endTime: endTime)
        }
        return outcome
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

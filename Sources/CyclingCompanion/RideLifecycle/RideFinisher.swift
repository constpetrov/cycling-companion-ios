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
    let uploader: RideUploader

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
    ///
    /// The finish lock covers only the local part. It is released before the upload, so a slow
    /// network can't stop the next ride from starting or finishing.
    @discardableResult
    func finishRide(_ liveRide: LiveRide) async -> FinishOutcome? {
        guard let (outcome, endTime) = await finalize(liveRide) else { return nil }
        if case .saved = outcome {
            await uploadRide(tracker: liveRide.tracker, session: liveRide.session, endTime: endTime)
        }
        return outcome
    }

    /// Ends the ride, writes the final record and shows the summary, all under the finish lock.
    /// Returns `nil` when another finish already holds the lock.
    private func finalize(_ liveRide: LiveRide) async -> (FinishOutcome, Date)? {
        guard rideCoordinator.beginFinishingRide() else { return nil }
        defer { rideCoordinator.endFinishingRide() }

        rideCoordinator.end(liveRide)

        let tracker = liveRide.tracker
        let endTime = Date()
        // A checkpoint still in flight (from the cancelled fix loop or a suggestion answer) would
        // otherwise be able to land after the final write and leave the ride unfinished.
        await tracker.stopCheckpointing()
        let outcome: FinishOutcome
        let suggestionState = await liveRide.session.suggestionLedger().persisted
        do {
            let saved = try await rideRecorder.finalize(
                rideId: tracker.rideId, routeId: tracker.routeId, startTime: tracker.startTime, endTime: endTime,
                totalDistanceMeters: tracker.distanceAlongRouteMeters,
                totalMovingTimeSeconds: tracker.movingTimeSeconds, track: tracker.track,
                suggestionState: suggestionState)
            outcome = .saved(saved)
        } catch {
            outcome = .notSaved
            Self.log.error(
                "Finalizing ride \(tracker.rideId, privacy: .public) failed: \(String(describing: error), privacy: .public) — it will resume on next launch")
        }

        rideCoordinator.presentSummary(outcome)
        return (outcome, endTime)
    }

    /// RULE-5/RULE-7/RULE-8/RULE-10/RULE-11 in spec/rules.md (AC-4 through AC-13): computes
    /// `stopsTaken`/`outcome` on-device, uploads immediately, and queues for retry at the next
    /// launch on any failure — never blocks `finishRide` on the network.
    private func uploadRide(tracker: RideTracker, session: RideSession, endTime: Date) async {
        // RULE-22: keyed by the local ride id, so a retry replaces rather than duplicates.
        let historicalRides = (try? await rideStore.fetchAll()) ?? []
        let stopsTaken = RideOutcomeCalculator.stopsTaken(
            postedNotifications: decisionLog.postedNotifications, track: tracker.track)
        let outcome = RideOutcomeCalculator.outcome(
            thisRideDistanceMeters: tracker.distanceAlongRouteMeters, historicalRides: historicalRides)
        let snapshots = await session.featureSnapshots()

        let suggestionResponses = await session.suggestionLedger().finalResponses.map(SuggestionResponsePayload.init)

        let payload = RideIngestRequestPayload(
            routeId: tracker.routeId, startTime: tracker.startTime, endTime: endTime,
            totalDistanceMeters: tracker.distanceAlongRouteMeters, totalMovingTimeSeconds: tracker.movingTimeSeconds,
            stopsTaken: stopsTaken, outcome: outcome.rawValue, featureSnapshots: snapshots.map(FeatureSnapshotPayload.init),
            suggestionResponses: suggestionResponses)

        await uploader.upload(payload, rideId: tracker.rideId)
    }
}

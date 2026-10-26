import Foundation

/// RULE-7 in spec/rules.md (AC-5/AC-6, Risk Hotspot 5 in spec/review.md): retries queued Ride
/// Ingest uploads at launch, bounded to a small batch so a long offline streak can't delay the
/// app becoming responsive. Mirrors `RideResumer`'s own launch-time pattern.
struct PendingRideUploadRetrier {
    static let maxUploadsPerLaunch = 5
    private static let log = Log.logger(category: "RideIngest")

    let pendingUploadQueue: PendingRideUploadQueue
    let rideIngestClient: RideIngestClient

    func retryPendingUploads() async {
        guard let pending = try? await pendingUploadQueue.fetchAllOldestFirst(), !pending.isEmpty else {
            return
        }
        var succeeded = 0
        for upload in pending.prefix(Self.maxUploadsPerLaunch) {
            // Milestone 9 (RULE-19): the queue is keyed by the local ride id, so even an upload queued
            // before clientRideId existed is sent linked to its ride.
            if await rideIngestClient.ingest(upload.payload.linked(toRide: upload.id)) {
                try? await pendingUploadQueue.remove(id: upload.id)
                succeeded += 1
            }
        }
        Self.log.info(
            "Retried \(min(pending.count, Self.maxUploadsPerLaunch), privacy: .public) of \(pending.count, privacy: .public) queued ride uploads, \(succeeded, privacy: .public) succeeded"
        )
    }
}

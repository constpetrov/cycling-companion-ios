import Foundation
import RoutePersistence

/// RULE-7 in spec/rules.md (AC-5/AC-6, Risk Hotspot 5 in spec/review.md): retries queued Ride
/// Ingest uploads at launch, bounded to a small batch so a long offline streak can't delay the
/// app becoming responsive. Mirrors `RideResumer`'s own launch-time pattern.
struct PendingRideUploadRetrier {
    static let maxUploadsPerLaunch = 5
    private static let log = Log.logger(category: "RideIngest")

    let pendingUploadQueue: PendingRideUploadQueue
    let rideIngestClient: RideIngestClient
    let rideStore: RideStore

    func retryPendingUploads() async {
        guard let pending = try? await pendingUploadQueue.fetchAllOldestFirst(), !pending.isEmpty else {
            return
        }
        var succeeded = 0
        for upload in pending.prefix(Self.maxUploadsPerLaunch) {
            if await rideIngestClient.ingest(upload.payload, rideId: await rideId(of: upload)) {
                try? await pendingUploadQueue.remove(id: upload.id)
                succeeded += 1
            }
        }
        Self.log.info(
            "Retried \(min(pending.count, Self.maxUploadsPerLaunch), privacy: .public) of \(pending.count, privacy: .public) queued ride uploads, \(succeeded, privacy: .public) succeeded"
        )
    }

    /// Milestone 9 (RULE-19): the local ride id to send `upload` linked to. Uploads queued since
    /// milestone 9 carry it. Older ones are keyed by it only since the queue was keyed by ride id;
    /// before that their id was random, so the queue id counts only when a saved ride has it.
    private func rideId(of upload: PendingRideUpload) async -> String? {
        if let clientRideId = upload.payload.clientRideId {
            return clientRideId
        }
        return (try? await rideStore.fetch(rideId: upload.id)) != nil ? upload.id : nil
    }
}

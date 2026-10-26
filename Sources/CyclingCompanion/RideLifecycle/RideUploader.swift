import Foundation

/// Uploads a finished ride and reports how it went, for the ride summary (RULE-22 in milestone 7's
/// rules.md, AC-79 to AC-83). A failed upload goes to `PendingRideUploadQueue` under the ride's id;
/// Retry now tries that ride again and removes it from the queue when it gets through.
@MainActor
@Observable
final class RideUploader {
    enum Status: Equatable {
        case uploading
        case saved
        case queued
    }

    /// The status of the most recently finished ride's upload; `nil` before any.
    private(set) var status: Status?

    private let ingestClient: RideIngestClient
    private let queue: PendingRideUploadQueue
    private var current: (rideId: String, payload: RideIngestRequestPayload)?

    init(ingestClient: RideIngestClient, queue: PendingRideUploadQueue) {
        self.ingestClient = ingestClient
        self.queue = queue
    }

    func upload(_ payload: RideIngestRequestPayload, rideId: String) async {
        let payload = payload.linked(toRide: rideId)
        current = (rideId, payload)
        status = .uploading
        if await ingestClient.ingest(payload) {
            status = .saved
        } else {
            try? await queue.enqueue(payload, id: rideId)
            status = .queued
        }
    }

    /// AC-82/AC-83: only meaningful while the current ride is queued.
    func retryNow() async {
        guard status == .queued, let current else { return }
        status = .uploading
        if await ingestClient.ingest(current.payload.linked(toRide: current.rideId)) {
            try? await queue.remove(id: current.rideId)
            status = .saved
        } else {
            try? await queue.enqueue(current.payload, id: current.rideId)
            status = .queued
        }
    }
}

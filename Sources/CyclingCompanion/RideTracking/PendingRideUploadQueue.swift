import Foundation

struct PendingRideUpload: Codable, Identifiable {
    let id: String
    let enqueuedAt: Date
    let payload: RideIngestRequestPayload
}

/// A small local queue of Ride Ingest uploads that failed (RULE-7 in spec/rules.md, AC-5/AC-6)
/// — same JSON-file persistence pattern as `RouteStore`/`RideStore`. Retried at the next app
/// launch (mirroring `RideResumer`'s launch-time pattern), not by a continuously-running
/// background loop.
actor PendingRideUploadQueue {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Queues `payload` under `id` — the local ride id for finished rides (RULE-22 in milestone 7's
    /// rules.md). Enqueueing an id that is already queued replaces that entry, so retrying a ride
    /// never leaves two copies of it.
    func enqueue(_ payload: RideIngestRequestPayload, id: String = UUID().uuidString) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        all.append(PendingRideUpload(id: id, enqueuedAt: Date(), payload: payload))
        try save(all)
    }

    /// Oldest-first (RULE-7, Risk Hotspot 5 in spec/review.md) — callers bound how many of
    /// these they actually retry per launch; this just orders them.
    func fetchAllOldestFirst() throws -> [PendingRideUpload] {
        try loadAll().sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    func remove(id: String) throws {
        var all = try loadAll()
        all.removeAll { $0.id == id }
        try save(all)
    }

    private func loadAll() throws -> [PendingRideUpload] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([PendingRideUpload].self, from: data)
    }

    private func save(_ all: [PendingRideUpload]) throws {
        let data = try JSONEncoder().encode(all)
        try data.write(to: fileURL, options: .atomic)
    }
}

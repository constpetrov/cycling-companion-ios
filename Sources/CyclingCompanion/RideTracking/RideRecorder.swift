import Foundation
import RoutePersistence

/// The single authoritative end-of-ride write (RULE-11 in spec/rules.md): the only place that
/// ever sets `endTime` on a `PersistedRide`. `RideTracker` checkpoints the same id throughout
/// the ride with `endTime` left unset (RULE-12); this call supersedes that last checkpoint
/// with the completed record, invoked only once, when the ride ends.
struct RideRecorder {
    private let rideStore: RideStore

    init(rideStore: RideStore) {
        self.rideStore = rideStore
    }

    /// AC-18: persists the completed Ride record — route id, start/end time, total distance,
    /// total moving time, and the full raw track — to the local store.
    func finalize(
        rideId: String, routeId: String, startTime: Date, endTime: Date, totalDistanceMeters: Double,
        totalMovingTimeSeconds: Double, track: [PersistedRideSample]
    ) async throws {
        let ride = PersistedRide(
            id: rideId, routeId: routeId, startTime: startTime, endTime: endTime,
            totalDistanceMeters: totalDistanceMeters, totalMovingTimeSeconds: totalMovingTimeSeconds, track: track)
        try await rideStore.persist(ride)
    }
}

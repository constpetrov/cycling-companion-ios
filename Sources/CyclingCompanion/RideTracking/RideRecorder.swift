import Foundation
import RoutePersistence

/// The single authoritative end-of-ride write (RULE-11 in spec/rules.md): the only place that
/// ever sets `endTime` on a `PersistedRide`. `RideTracker` checkpoints the same id throughout
/// the ride with `endTime` left unset (RULE-12); this call supersedes that last checkpoint
/// with the completed record, invoked only once, when the ride ends.
/// Writes the finished ride (`RideRecorder` in production). A protocol so a failing write can be
/// tested (AC-84 in milestone 7's criteria.md).
protocol RideFinalizing: Sendable {
    func finalize(
        rideId: String, routeId: String, startTime: Date, endTime: Date, totalDistanceMeters: Double,
        totalMovingTimeSeconds: Double, track: [PersistedRideSample], suggestionState: PersistedSuggestionState?
    ) async throws -> PersistedRide
}

struct RideRecorder: RideFinalizing {
    private let rideStore: RideStore

    init(rideStore: RideStore) {
        self.rideStore = rideStore
    }

    /// AC-18: persists the completed Ride record — route id, start/end time, total distance,
    /// total moving time, and the full raw track — to the local store.
    @discardableResult
    func finalize(
        rideId: String, routeId: String, startTime: Date, endTime: Date, totalDistanceMeters: Double,
        totalMovingTimeSeconds: Double, track: [PersistedRideSample], suggestionState: PersistedSuggestionState? = nil
    ) async throws -> PersistedRide {
        let ride = PersistedRide(
            id: rideId, routeId: routeId, startTime: startTime, endTime: endTime,
            totalDistanceMeters: totalDistanceMeters, totalMovingTimeSeconds: totalMovingTimeSeconds, track: track,
            suggestionState: suggestionState)
        try await rideStore.persist(ride)
        return ride
    }
}

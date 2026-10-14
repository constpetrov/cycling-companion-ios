import Foundation
import RoutePersistence

/// A rider's personal baselines (RULE-1/RULE-3/RULE-4 in spec/rules.md, AC-1/AC-2/AC-3) —
/// computed entirely from the phone's own local ride history, no backend involved. `nil` below
/// 5 recorded finished rides (design.md's own "about five," pinned to exactly 5 per spec.md).
///
/// RULE-3/RULE-4's deliberate simplification: design.md describes `speedVsBaseline` as
/// "current grade-adjusted speed against this rider's speed at the same grade from past
/// rides" — a grade-bucketed curve. This computes a single overall average moving speed
/// instead, because a true grade-bucketed comparison would need every past ride's own route
/// geometry re-fetched and re-processed, and neither field this feeds is consumed by any
/// on-device threshold (`LocalTrigger` doesn't reference them) — they're LLM-prompt context
/// only, so the simpler, cheaper ratio over already-stored aggregate fields is sufficient. See
/// review.md's Risk Hotspot 1 — this is a deliberate, documented divergence, not an oversight.
struct PersonalBaselines: Sendable, Equatable {
    let averageMovingSpeedMetersPerSecond: Double
    let maximumDistanceMeters: Double
}

enum BaselineCalculator {
    private static let minimumRideCount = 5

    /// `nil` below the 5-ride floor (AC-1); otherwise computed from every locally-recorded
    /// *finished* ride's already-stored aggregate fields (AC-2/AC-3) — never re-processing raw
    /// tracks or re-fetching historical routes.
    static func compute(from rides: [PersistedRide]) -> PersonalBaselines? {
        let finishedRides = rides.filter { $0.endTime != nil }
        guard finishedRides.count >= minimumRideCount else {
            return nil
        }
        let movingSpeeds = finishedRides.compactMap { ride -> Double? in
            guard ride.totalMovingTimeSeconds > 0 else { return nil }
            return ride.totalDistanceMeters / ride.totalMovingTimeSeconds
        }
        guard !movingSpeeds.isEmpty else {
            return nil
        }
        let averageSpeed = movingSpeeds.reduce(0, +) / Double(movingSpeeds.count)
        let maxDistance = finishedRides.map(\.totalDistanceMeters).max() ?? 0
        return PersonalBaselines(averageMovingSpeedMetersPerSecond: averageSpeed, maximumDistanceMeters: maxDistance)
    }

    /// Convenience overload reading directly from a `RideStore` (RULE-1: no backend round trip).
    static func compute(from rideStore: RideStore) async -> PersonalBaselines? {
        let rides = (try? await rideStore.fetchAll()) ?? []
        return compute(from: rides)
    }
}

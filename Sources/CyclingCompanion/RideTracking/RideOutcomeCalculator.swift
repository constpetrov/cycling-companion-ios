import Foundation
import RoutePersistence
import UserNotifications

/// A finished ride's outcome relative to the rider's own history (RULE-11 in spec/rules.md,
/// AC-11/AC-12/AC-13) — not a ride-lifecycle state; every uploadable ride is already
/// "completed" by construction (`RideRecorder.finalize` is the sole write to `RideStore`).
enum RideOutcome: String, Sendable {
    case longerThanUsual = "LONGER_THAN_USUAL"
    case typical = "TYPICAL"
    case shorterThanUsual = "SHORTER_THAN_USUAL"
}

/// Computes a finished ride's `stopsTaken` and `outcome` (RULE-8/RULE-9/RULE-10/RULE-11 in
/// spec/rules.md, AC-7 through AC-13) — pure, called once at `RideFinisher`'s finalize time.
enum RideOutcomeCalculator {
    private static let stopProximityRadiusMeters = 100.0
    private static let typicalBandFraction = 0.20

    /// RULE-8/RULE-9: scans the ride's entire finished track (not bounded to "after the
    /// notification" — `DecisionLog` doesn't timestamp posted notifications, and POI Lookahead
    /// only ever suggests stops still ahead of the rider, so a whole-track scan is a safe,
    /// documented over-approximation — Risk Hotspot 4 in spec/review.md) for a fix within 100m
    /// (inclusive) of each posted notification's stop location. Skips any notification whose
    /// stored coordinates are exactly `(0, 0)` — `Notifier`'s own existing fallback for an
    /// unmatched candidate, which must never be treated as a real stop location.
    static func stopsTaken(postedNotifications: [UNNotificationRequest], track: [PersistedRideSample]) -> Int {
        postedNotifications.filter { notification in
            guard let latitude = notification.content.userInfo["latitude"] as? Double,
                let longitude = notification.content.userInfo["longitude"] as? Double,
                !(latitude == 0 && longitude == 0)
            else {
                return false
            }
            let stopPoint = TrackPoint(latitude: latitude, longitude: longitude, elevationMeters: nil)
            return track.contains { sample in
                let samplePoint = TrackPoint(
                    latitude: sample.latitude, longitude: sample.longitude, elevationMeters: nil)
                return isWithinStopRadius(distanceMeters: GeoMath.haversineDistanceMeters(stopPoint, samplePoint))
            }
        }.count
    }

    /// RULE-9: a separate, directly-testable comparison — geometric computation can't reliably
    /// land on the literal floating-point value `100.0`, so the inclusive-boundary behavior
    /// itself is tested against this function directly, not indirectly through geometry.
    static func isWithinStopRadius(distanceMeters: Double) -> Bool {
        distanceMeters <= stopProximityRadiusMeters
    }

    /// RULE-11: relative to the rider's own historical average distance (the same `RideStore`
    /// read `BaselineCalculator` uses) — within 20% is `.typical`, more than 20% over/under is
    /// `.longerThanUsual`/`.shorterThanUsual`. No historical rides (nothing to compare against)
    /// reads as `.typical`.
    static func outcome(thisRideDistanceMeters: Double, historicalRides: [PersistedRide]) -> RideOutcome {
        let finished = historicalRides.filter { $0.endTime != nil }
        guard !finished.isEmpty else {
            return .typical
        }
        let averageDistance = finished.map(\.totalDistanceMeters).reduce(0, +) / Double(finished.count)
        guard averageDistance > 0 else {
            return .typical
        }
        let ratio = thisRideDistanceMeters / averageDistance
        if ratio > 1 + typicalBandFraction {
            return .longerThanUsual
        }
        if ratio < 1 - typicalBandFraction {
            return .shorterThanUsual
        }
        return .typical
    }
}

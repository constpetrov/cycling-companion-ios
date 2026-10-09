import SwiftUI

/// A standalone live progress screen (AC-14/15/16/17 in spec/criteria.md) — no navigation
/// wiring this milestone (spec.md). Bound directly to a `RideTracker` instance: reads its
/// `@Observable` properties, so SwiftUI re-renders whenever one changes. The display values
/// are exposed as plain properties (not just inside `body`), matching `CorridorMapView`'s
/// testing convention — tests assert on these directly rather than inspecting rendered output.
struct RideProgressView: View {
    let rideTracker: RideTracker

    /// AC-14.
    var distanceDoneMeters: Double {
        rideTracker.distanceAlongRouteMeters
    }

    /// AC-14.
    var distanceRemainingMeters: Double {
        max(rideTracker.totalRouteDistanceMeters - rideTracker.distanceAlongRouteMeters, 0)
    }

    /// AC-15: `nil` is the explicit "no ETA yet" state, distinct from an ETA of zero.
    var etaSeconds: Double? {
        rideTracker.etaSeconds
    }

    /// AC-16: `nil` before the first location update.
    var currentSpeedMetersPerSecond: Double? {
        rideTracker.latestFix?.speedMetersPerSecond
    }

    /// AC-17: `nil` is the placeholder state (no reading / dropout).
    var currentHeartRateBPM: Int? {
        rideTracker.currentHeartRateBPM
    }

    /// AC-17: `nil` is the placeholder state (no reading / dropout).
    var currentCadenceRPM: Int? {
        rideTracker.currentCadenceRPM
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Distance done: \(formatted(meters: distanceDoneMeters))")
            Text("Distance remaining: \(formatted(meters: distanceRemainingMeters))")
            Text("ETA: \(etaSeconds.map(formatted(duration:)) ?? "—")")
            Text("Speed: \(currentSpeedMetersPerSecond.map { String(format: "%.1f m/s", $0) } ?? "—")")
            Text("Heart rate: \(currentHeartRateBPM.map { "\($0) bpm" } ?? "—")")
            Text("Cadence: \(currentCadenceRPM.map { "\($0) rpm" } ?? "—")")
        }
        .padding()
    }

    private func formatted(meters: Double) -> String {
        String(format: "%.0f m", meters)
    }

    private func formatted(duration seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

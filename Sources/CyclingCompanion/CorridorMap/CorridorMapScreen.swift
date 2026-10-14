import RoutePersistence
import SwiftUI

/// The corridor map screen (RULE-13/RULE-16 in spec/rules.md, AC-8/AC-9/AC-10/AC-11): renders
/// the imported route and POI pins via `CorridorMapView`, reactively bound to
/// `CorridorImportCoordinator`'s observed `pois` (empty with no pins before settle, populated
/// with pins after). Start Ride is never disabled or hidden regardless of settle state
/// (RULE-13) — `startRideIsEnabled` is unconditionally `true`, not gated on anything.
struct CorridorMapScreen: View {
    let coordinator: CorridorImportCoordinator
    let onStartRide: () -> Void

    /// RULE-13: Start Ride is never gated on whether corridor POIs have finished building.
    var startRideIsEnabled: Bool { true }

    var body: some View {
        VStack {
            CorridorMapView(points: coordinator.points, pois: coordinator.pois)
            Button("Start Ride", action: onStartRide)
                .disabled(!startRideIsEnabled)
        }
    }
}

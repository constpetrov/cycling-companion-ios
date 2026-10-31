import MapKit
import SwiftUI

/// The dashboard's full-screen map (RULE-11 in milestone 7's rules.md): route line, corridor stops
/// and the rider's position from the ride's own fixes. The camera follows `cameraCenter` until the
/// rider pans; then a Recenter control resumes following.
struct LiveRideMapView: View {
    let viewModel: LiveRideViewModel

    @State private var position: MapCameraPosition = .automatic

    /// Close enough to read the road, wide enough to see what's ahead.
    private static let followDistanceMeters: CLLocationDistance = 1_500

    /// Only the map runs edge to edge; the Recenter button stays inside the safe area, which the dashboard's top
    /// panel extends, so it sits just below the metrics instead of under the status bar.
    var body: some View {
        ZStack(alignment: .topTrailing) {
            map
                .ignoresSafeArea()
            if !viewModel.isFollowingRider {
                Button {
                    viewModel.recenter()
                } label: {
                    Label("Recenter", systemImage: "location.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    private var map: some View {
        Map(position: $position) {
            if viewModel.routeCoordinates.count >= 2 {
                MapPolyline(coordinates: viewModel.routeCoordinates)
                    .stroke(.blue, lineWidth: 4)
            }
            ForEach(viewModel.visibleStops, id: \.osmId) { stop in
                Marker(
                    stop.name ?? LiveRideViewModel.typeLabel(stop.type),
                    coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude))
                .tint(stop.osmId == viewModel.highlightedStopId ? .orange : .gray)
            }
            if let rider = viewModel.mapRiderCoordinate {
                Annotation("You", coordinate: rider) {
                    Circle()
                        .fill(.blue)
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 18, height: 18)
                        .shadow(radius: 2)
                }
            }
        }
        // AC-132 (RULE-28): VoiceOver gets the stops as a list instead of the map's pins.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route map")
        .accessibilityChildren {
            ForEach(viewModel.visibleStops, id: \.osmId) { stop in
                Text(viewModel.stopAccessibilityLabel(stop))
                    .accessibilityIdentifier("mapStop")
            }
        }
        .onChange(of: viewModel.cameraCenter.map { [$0.latitude, $0.longitude] }) { moveCamera() }
        // Recenter on a rider standing still sets the same centre, which the one above doesn't see.
        .onChange(of: viewModel.isFollowingRider) { _, following in
            if following { moveCamera() }
        }
        .onChange(of: position.positionedByUser) { _, byUser in
            if byUser { viewModel.riderDidPan() }
        }
    }

    private func moveCamera() {
        guard viewModel.isFollowingRider, let center = viewModel.cameraCenter else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            position = .camera(MapCamera(centerCoordinate: center, distance: Self.followDistanceMeters))
        }
    }
}

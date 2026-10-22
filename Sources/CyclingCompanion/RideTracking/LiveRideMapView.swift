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

    var body: some View {
        Map(position: $position) {
            if viewModel.routeCoordinates.count >= 2 {
                MapPolyline(coordinates: viewModel.routeCoordinates)
                    .stroke(.blue, lineWidth: 4)
            }
            ForEach(viewModel.stops, id: \.osmId) { stop in
                Marker(
                    stop.name ?? LiveRideViewModel.typeLabel(stop.type),
                    coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude))
                .tint(stop.osmId == viewModel.highlightedStopId ? .orange : .gray)
            }
            if let rider = viewModel.riderCoordinate {
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
            ForEach(viewModel.stops, id: \.osmId) { stop in
                Text(viewModel.stopAccessibilityLabel(stop))
                    .accessibilityIdentifier("mapStop")
            }
        }
        .onChange(of: viewModel.cameraCenter?.latitude) { moveCamera() }
        .onChange(of: viewModel.cameraCenter?.longitude) { moveCamera() }
        .onChange(of: position.positionedByUser) { _, byUser in
            if byUser { viewModel.riderDidPan() }
        }
        .overlay(alignment: .topTrailing) {
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

    private func moveCamera() {
        guard viewModel.isFollowingRider, let center = viewModel.cameraCenter else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            position = .camera(MapCamera(centerCoordinate: center, distance: Self.followDistanceMeters))
        }
    }
}

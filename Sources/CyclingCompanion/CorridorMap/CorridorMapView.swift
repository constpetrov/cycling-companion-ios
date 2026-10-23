import MapKit
import RoutePersistence
import SwiftUI

/// A single corridor POI pin (AC-30 in spec/criteria.md).
struct CorridorMapPin: Identifiable {
    let id: Int64
    let name: String?
    let type: String
    let coordinate: CLLocationCoordinate2D
    var kmMarkMeters: Double = 0
}

/// Renders the imported route's polyline and all of its corridor POI pins (AC-30/AC-31 in
/// spec/criteria.md). Takes plain data rather than reading the Route Store directly, so it can
/// be rendered/tested independently of however the caller sourced it.
struct CorridorMapView: View {
    let routeCoordinates: [CLLocationCoordinate2D]
    let pins: [CorridorMapPin]

    init(points: [PersistedPointInput], pois: [PersistedPoiInput]) {
        self.routeCoordinates = points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        // Before the ride: the 2 nearest stops of each type from the start (milestone 8 review).
        self.pins = MapStopSelection.nearestAhead(pois, from: 0).map {
            CorridorMapPin(
                id: $0.osmId, name: $0.name, type: $0.type,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                kmMarkMeters: $0.kmMarkMeters)
        }
    }

    init(route: PersistedRoute) {
        self.init(points: route.points, pois: route.pois)
    }

    /// AC-132 (RULE-28): what VoiceOver reads for each stop instead of the map's pins.
    var stopAccessibilityLabels: [String] {
        pins.sorted { $0.kmMarkMeters < $1.kmMarkMeters }.map { pin in
            let name = pin.name ?? LiveRideViewModel.typeLabel(pin.type)
            return "\(name), \(LiveRideViewModel.distanceText(meters: pin.kmMarkMeters, locale: .current)) along the route"
        }
    }

    var body: some View {
        Map {
            if routeCoordinates.count >= 2 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(.blue, lineWidth: 3)
            }
            ForEach(pins) { pin in
                Marker(pin.name ?? LiveRideViewModel.typeLabel(pin.type), coordinate: pin.coordinate)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route map")
        .accessibilityChildren {
            ForEach(Array(stopAccessibilityLabels.enumerated()), id: \.offset) {
                Text($0.element).accessibilityIdentifier("mapStop")
            }
        }
    }
}

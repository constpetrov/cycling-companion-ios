import MapKit
import RoutePersistence
import SwiftUI

/// A single corridor POI pin (AC-30 in spec/criteria.md).
struct CorridorMapPin: Identifiable {
    let id: Int64
    let name: String?
    let type: String
    let coordinate: CLLocationCoordinate2D
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
        self.pins = pois.map {
            CorridorMapPin(
                id: $0.osmId, name: $0.name, type: $0.type,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
    }

    init(route: PersistedRoute) {
        self.init(points: route.points, pois: route.pois)
    }

    var body: some View {
        Map {
            if routeCoordinates.count >= 2 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(.blue, lineWidth: 3)
            }
            ForEach(pins) { pin in
                Marker(pin.name ?? pin.type, coordinate: pin.coordinate)
            }
        }
    }
}

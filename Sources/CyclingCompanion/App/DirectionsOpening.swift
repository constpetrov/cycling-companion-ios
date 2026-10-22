import MapKit

/// Hands a stop to Apple Maps for directions (RULE-19 in milestone 7's rules.md). A protocol so
/// tests can check the hand-off without leaving the app.
@MainActor
protocol DirectionsOpening {
    func openDirections(toLatitude latitude: Double, longitude: Double, name: String)
}

/// Opens Apple Maps with cycling directions (available since iOS 14, so always on iOS 17+).
@MainActor
struct AppleMapsDirections: DirectionsOpening {
    func openDirections(toLatitude latitude: Double, longitude: Double, name: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeCycling])
    }
}

/// Does nothing; for previews and tests that don't check directions.
@MainActor
struct NoDirections: DirectionsOpening {
    func openDirections(toLatitude latitude: Double, longitude: Double, name: String) {}
}

import Foundation

/// Small geometry helpers shared by simplification and resampling.
enum GeoMath {
    static let earthRadiusMeters = 6_371_000.0

    /// Equirectangular projection to local flat meters, relative to `origin`. Accurate enough
    /// for the short distances (tens of meters) Douglas-Peucker compares against the 5 m
    /// tolerance (RULE-24 in spec/rules.md).
    static func flatMeters(_ point: TrackPoint, relativeTo origin: TrackPoint) -> (x: Double, y: Double) {
        let originLatRad = origin.latitude * .pi / 180
        let dLat = (point.latitude - origin.latitude) * .pi / 180
        let dLon = (point.longitude - origin.longitude) * .pi / 180
        let x = dLon * cos(originLatRad) * earthRadiusMeters
        let y = dLat * earthRadiusMeters
        return (x, y)
    }

    /// Great-circle distance between two points, in meters.
    static func haversineDistanceMeters(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let sinDLat = sin(dLat / 2)
        let sinDLon = sin(dLon / 2)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }
}

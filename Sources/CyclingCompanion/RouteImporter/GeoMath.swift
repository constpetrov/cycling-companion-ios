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

    /// Result of projecting a point onto the nearest spot on a route's polyline.
    struct ClosestPointResult {
        let distanceAlongRouteMeters: Double
        let offRouteMeters: Double
    }

    /// Finds the closest point on the route polyline to (latitude, longitude), returning that
    /// point's cumulative distance along the route and the straight-line distance from the
    /// query point to it (RULE-9 in spec/rules.md) — ported from the backend's
    /// `GeoMath.closestPointOnRoute` (Java), same equirectangular-projection approach.
    static func closestPointOnRoute(
        latitude: Double, longitude: Double, route: [ResampledPoint],
        progressRange: ClosedRange<Double>? = nil
    ) -> ClosestPointResult {
        let queryPoint = TrackPoint(latitude: latitude, longitude: longitude, elevationMeters: nil)

        if route.count <= 1 {
            guard let only = route.first else {
                return ClosestPointResult(distanceAlongRouteMeters: 0, offRouteMeters: 0)
            }
            let onlyPoint = TrackPoint(latitude: only.latitude, longitude: only.longitude, elevationMeters: nil)
            return ClosestPointResult(
                distanceAlongRouteMeters: only.cumulativeDistanceMeters,
                offRouteMeters: haversineDistanceMeters(queryPoint, onlyPoint))
        }

        var bestOffRoute = Double.greatestFiniteMagnitude
        var bestDistanceAlongRoute = 0.0

        for i in 0..<(route.count - 1) {
            let a = route[i]
            let b = route[i + 1]
            let aPoint = TrackPoint(latitude: a.latitude, longitude: a.longitude, elevationMeters: nil)
            let bPoint = TrackPoint(latitude: b.latitude, longitude: b.longitude, elevationMeters: nil)

            let (bx, by) = flatMeters(bPoint, relativeTo: aPoint)
            let (px, py) = flatMeters(queryPoint, relativeTo: aPoint)

            let lengthSquared = bx * bx + by * by
            let t = lengthSquared > 0 ? (px * bx + py * by) / lengthSquared : 0
            let clampedT = max(0, min(1, t))

            let offRoute = hypot(px - clampedT * bx, py - clampedT * by)
            let segmentLength = b.cumulativeDistanceMeters - a.cumulativeDistanceMeters
            let distanceAlongRoute = a.cumulativeDistanceMeters + clampedT * segmentLength

            // A loop's start and finish can share the same coordinates. Restrict matching
            // to reachable progress when the caller has a previous fix; small backtracking
            // remains valid, but a GPS wobble cannot jump to another lap/route branch.
            if let progressRange, !progressRange.contains(distanceAlongRoute) {
                continue
            }

            if offRoute < bestOffRoute {
                bestOffRoute = offRoute
                bestDistanceAlongRoute = distanceAlongRoute
            }
        }

        return ClosestPointResult(distanceAlongRouteMeters: bestDistanceAlongRoute, offRouteMeters: bestOffRoute)
    }
}

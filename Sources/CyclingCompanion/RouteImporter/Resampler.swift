import Foundation

/// Fixed-distance resampling along the simplified polyline (RULE-24 in spec/rules.md,
/// AC-6/AC-7/AC-8 in spec/criteria.md).
enum Resampler {
    static func totalPolylineLengthMeters(_ points: [TrackPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(points.count - 1) {
            total += GeoMath.haversineDistanceMeters(points[i], points[i + 1])
        }
        return total
    }

    static func resample(_ points: [TrackPoint], stepMeters: Double) -> [ResampledPoint] {
        guard points.count >= 2 else {
            return points.map {
                ResampledPoint(
                    latitude: $0.latitude, longitude: $0.longitude, elevationMeters: $0.elevationMeters,
                    cumulativeDistanceMeters: 0)
            }
        }

        let totalLength = totalPolylineLengthMeters(points)

        var result: [ResampledPoint] = [
            ResampledPoint(
                latitude: points[0].latitude, longitude: points[0].longitude,
                elevationMeters: points[0].elevationMeters, cumulativeDistanceMeters: 0)
        ]

        var segmentIndex = 0
        var cumulativeAtSegmentStart = 0.0
        var segmentLength = GeoMath.haversineDistanceMeters(points[0], points[1])
        var nextTarget = stepMeters

        while nextTarget < totalLength {
            while segmentIndex < points.count - 2, cumulativeAtSegmentStart + segmentLength < nextTarget {
                cumulativeAtSegmentStart += segmentLength
                segmentIndex += 1
                segmentLength = GeoMath.haversineDistanceMeters(points[segmentIndex], points[segmentIndex + 1])
            }

            let t = segmentLength > 0 ? (nextTarget - cumulativeAtSegmentStart) / segmentLength : 0
            let a = points[segmentIndex]
            let b = points[segmentIndex + 1]
            let latitude = a.latitude + (b.latitude - a.latitude) * t
            let longitude = a.longitude + (b.longitude - a.longitude) * t
            let elevation: Double? = {
                guard let elevationA = a.elevationMeters, let elevationB = b.elevationMeters else { return nil }
                return elevationA + (elevationB - elevationA) * t
            }()

            result.append(
                ResampledPoint(
                    latitude: latitude, longitude: longitude, elevationMeters: elevation,
                    cumulativeDistanceMeters: nextTarget))
            nextTarget += stepMeters
        }

        let last = points[points.count - 1]
        result.append(
            ResampledPoint(
                latitude: last.latitude, longitude: last.longitude, elevationMeters: last.elevationMeters,
                cumulativeDistanceMeters: totalLength))

        return result
    }
}

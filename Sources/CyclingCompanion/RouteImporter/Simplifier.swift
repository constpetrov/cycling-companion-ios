import Foundation

/// Douglas-Peucker track simplification at a fixed tolerance (RULE-24 in spec/rules.md,
/// AC-5 in spec/criteria.md). Runs before resampling.
enum Simplifier {
    static func simplify(_ points: [TrackPoint], toleranceMeters: Double) -> [TrackPoint] {
        guard points.count > 2 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifyRange(points, 0, points.count - 1, toleranceMeters, &keep)
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func simplifyRange(
        _ points: [TrackPoint], _ start: Int, _ end: Int, _ tolerance: Double, _ keep: inout [Bool]
    ) {
        guard end > start + 1 else { return }

        var maxDistance = 0.0
        var maxIndex = start
        for i in (start + 1)..<end {
            let distance = perpendicularDistanceMeters(points[i], lineStart: points[start], lineEnd: points[end])
            if distance > maxDistance {
                maxDistance = distance
                maxIndex = i
            }
        }

        if maxDistance > tolerance {
            keep[maxIndex] = true
            simplifyRange(points, start, maxIndex, tolerance, &keep)
            simplifyRange(points, maxIndex, end, tolerance, &keep)
        }
    }

    private static func perpendicularDistanceMeters(
        _ point: TrackPoint, lineStart: TrackPoint, lineEnd: TrackPoint
    ) -> Double {
        let p = GeoMath.flatMeters(point, relativeTo: lineStart)
        let b = GeoMath.flatMeters(lineEnd, relativeTo: lineStart)

        let lengthSquared = b.x * b.x + b.y * b.y
        guard lengthSquared > 0 else {
            return hypot(p.x, p.y)
        }

        let t = (p.x * b.x + p.y * b.y) / lengthSquared
        let clampedT = max(0, min(1, t))
        let projectedX = clampedT * b.x
        let projectedY = clampedT * b.y
        return hypot(p.x - projectedX, p.y - projectedY)
    }
}

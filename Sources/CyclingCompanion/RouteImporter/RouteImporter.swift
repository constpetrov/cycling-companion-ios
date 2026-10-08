import Foundation

/// Parses, simplifies, resamples, and hashes GPX routes (RULE-22/24 in spec/rules.md,
/// AC-2/3/5/6/7/8/9/10 in spec/criteria.md). The 20 MB size-cap check (RULE-23) and the
/// malformed/under-minimum rejection UX land in task-4.1; the underlying error cases are
/// already raised here since the parser inherently needs to detect them.
enum RouteImporter {
    static let simplifyToleranceMeters = 5.0
    static let resampleStepMeters = 50.0

    static func importGPX(data: Data) throws -> ImportedRoute {
        let rawPoints = try GPXTrackPointParser().parse(data: data)
        guard rawPoints.count >= 2 else {
            throw RouteImporterError.insufficientTrackPoints
        }

        let hasElevation = rawPoints.allSatisfy { $0.elevationMeters != nil }

        let simplified = Simplifier.simplify(rawPoints, toleranceMeters: simplifyToleranceMeters)
        var resampled = Resampler.resample(simplified, stepMeters: resampleStepMeters)

        if !hasElevation {
            resampled = resampled.map {
                ResampledPoint(
                    latitude: $0.latitude, longitude: $0.longitude, elevationMeters: nil,
                    cumulativeDistanceMeters: $0.cumulativeDistanceMeters)
            }
        }

        let totalDistance = resampled.last?.cumulativeDistanceMeters ?? 0
        let totalClimbing = hasElevation ? climbingMeters(resampled) : nil
        let hash = RouteHasher.hash(resampled)

        return ImportedRoute(
            points: resampled, totalDistanceMeters: totalDistance, totalClimbingMeters: totalClimbing,
            hash: hash)
    }

    private static func climbingMeters(_ points: [ResampledPoint]) -> Double {
        var climbing = 0.0
        for i in 1..<points.count {
            if let previous = points[i - 1].elevationMeters, let current = points[i].elevationMeters,
                current > previous
            {
                climbing += current - previous
            }
        }
        return climbing
    }
}

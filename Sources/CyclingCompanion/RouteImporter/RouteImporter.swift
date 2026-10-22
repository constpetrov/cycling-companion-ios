import Foundation

/// Parses, simplifies, resamples, and hashes GPX routes (RULE-22/24 in spec/rules.md,
/// AC-2/3/5/6/7/8/9/10 in spec/criteria.md).
enum RouteImporter {
    static let simplifyToleranceMeters = 5.0
    static let resampleStepMeters = 50.0
    static let maxFileSizeBytes = 20 * 1024 * 1024

    /// Entry point for a locally-picked file (AC-42/43/44, RULE-23): checks the file's size via
    /// file-system metadata — not `Data.count` — before ever opening it with `XMLParser`, so an
    /// oversized file is rejected without reading its contents into memory at all.
    static func importGPX(fileURL: URL) throws -> ImportedRoute {
        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSizeBytes = resourceValues.fileSize, fileSizeBytes <= maxFileSizeBytes else {
            throw RouteImporterError.fileTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        var route = try importGPX(data: data)
        if route.displayName == nil {
            route.displayName = fileURL.deletingPathExtension().lastPathComponent
        }
        return route
    }

    /// RULE-26 (milestone 7): the display name is the GPX track name, else the metadata name; a
    /// file import falls back to the file name.
    static func importGPX(data: Data) throws -> ImportedRoute {
        let parser = GPXTrackPointParser()
        let rawPoints = try parser.parse(data: data)
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
            hash: hash, displayName: parser.trackName ?? parser.metadataName)
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

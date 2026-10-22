import Foundation

/// A single GPX track point, before simplification/resampling.
struct TrackPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double?
}

/// A point on the simplified, resampled route (RULE-24 in spec/rules.md).
struct ResampledPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double?
    let cumulativeDistanceMeters: Double
}

/// Result of a successful GPX import (AC-2 through AC-10 in spec/criteria.md).
struct ImportedRoute: Equatable {
    let points: [ResampledPoint]
    let totalDistanceMeters: Double
    let totalClimbingMeters: Double?
    let hash: String
    /// RULE-26 (milestone 7): kept on the phone, never sent in the import request.
    var displayName: String? = nil
}

enum RouteImporterError: Error, Equatable {
    case malformedGPX
    case insufficientTrackPoints
    case fileTooLarge
}

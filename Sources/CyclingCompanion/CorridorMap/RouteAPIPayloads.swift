import Foundation

/// Wire shapes matching the backend's ImportRouteRequest/CorridorStatusResponse (RULE-25 in
/// spec/rules.md).
struct RoutePointPayload: Encodable, Decodable, Sendable {
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double?
    let cumulativeDistanceMeters: Double
}

struct ImportRouteRequestPayload: Encodable, Sendable {
    let hash: String
    let points: [RoutePointPayload]
    let totalDistanceMeters: Double
    let totalClimbingMeters: Double?
}

struct ImportRouteResponsePayload: Decodable, Sendable {
    let routeId: String
    let status: String
}

/// One concrete weekly open window (RULE-32 in spec/rules.md), mirroring the backend's
/// `WeeklyOpenInterval` record field-for-field. `dayOfWeek` is ISO-8601 (1 = Monday..7 = Sunday).
struct WeeklyOpenIntervalPayload: Decodable, Sendable {
    let dayOfWeek: Int
    let startMinuteOfDay: Int
    let endMinuteOfDay: Int
}

/// Mirrors the backend's `NormalizedOpeningHours` record field-for-field (RULE-32).
struct NormalizedOpeningHoursPayload: Decodable, Sendable {
    let alwaysOpen: Bool
    let unknown: Bool
    let intervals: [WeeklyOpenIntervalPayload]
}

struct CorridorPoiResponse: Decodable, Sendable {
    let osmId: Int64
    let type: String
    let name: String?
    let latitude: Double
    let longitude: Double
    let kmMarkMeters: Double
    let detourMeters: Double
    let openingHours: String?
    /// Non-optional: a fresh corridor fetch always populates this (RULE-15/RULE-16 guarantee
    /// normalization always produces *some* result, even if `unknown: true`).
    let normalizedOpeningHours: NormalizedOpeningHoursPayload
}

struct CorridorStatusResponsePayload: Decodable, Sendable {
    let status: String
    let pois: [CorridorPoiResponse]?
}

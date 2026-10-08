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

struct CorridorPoiResponse: Decodable, Sendable {
    let osmId: Int64
    let type: String
    let name: String?
    let latitude: Double
    let longitude: Double
    let kmMarkMeters: Double
    let detourMeters: Double
    let openingHours: String?
}

struct CorridorStatusResponsePayload: Decodable, Sendable {
    let status: String
    let pois: [CorridorPoiResponse]?
}

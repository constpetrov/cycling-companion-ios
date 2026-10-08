import Foundation
import SwiftData

/// SwiftData persistence for Route and CorridorPOI records (AC-29 in spec/criteria.md).
///
/// Lives in its own local Swift Package, not the main app module (see the earlier cross-module
/// investigation in spec/status.md, task-2.6 notes). Points and POIs are stored as JSON-encoded
/// `Data` on a single flat `RouteModel` rather than as separate `@Model` classes linked via
/// `@Relationship`: on this Xcode 27/iOS 27 SDK, populating a `@Relationship` array with real
/// child objects and then reading it back after a fetch reproducibly crashes
/// ("Could not cast value of type '__NSCFNumber' to 'NSString'"), independent of the
/// plain-string-count issue also present on this SDK (worked around separately by keeping
/// `RouteModel`'s own stored properties to 2 plain strings). A flat model with no relationships
/// avoids the relationship-fault-resolution code path entirely. Revisit if a future SDK fixes
/// this; a normalized schema is the more natural long-term shape once querying individual
/// points/POIs independently is ever needed.
public enum CorridorStatusRaw: Int, Sendable {
    case building = 0
    case ready = 1
    case failed = 2

    public init(_ value: String) {
        switch value {
        case "ready": self = .ready
        case "failed": self = .failed
        default: self = .building
        }
    }

    public var stringValue: String {
        switch self {
        case .building: "building"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}

public struct PersistedPointInput: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let elevationMeters: Double?
    public let cumulativeDistanceMeters: Double

    public init(latitude: Double, longitude: Double, elevationMeters: Double?, cumulativeDistanceMeters: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevationMeters = elevationMeters
        self.cumulativeDistanceMeters = cumulativeDistanceMeters
    }
}

public struct PersistedPoiInput: Codable, Sendable {
    public let osmId: Int64
    public let type: String
    public let name: String?
    public let latitude: Double
    public let longitude: Double
    public let kmMarkMeters: Double
    public let detourMeters: Double
    public let openingHours: String?

    public init(
        osmId: Int64, type: String, name: String?, latitude: Double, longitude: Double,
        kmMarkMeters: Double, detourMeters: Double, openingHours: String?
    ) {
        self.osmId = osmId
        self.type = type
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.kmMarkMeters = kmMarkMeters
        self.detourMeters = detourMeters
        self.openingHours = openingHours
    }
}

@Model
public final class RouteModel {
    @Attribute(.unique) public var id: String
    public var hash: String
    public var totalDistanceMeters: Double
    public var totalClimbingMeters: Double?
    public var statusRaw: Int
    public var pointsData: Data
    public var poisData: Data

    public var status: String {
        (CorridorStatusRaw(rawValue: statusRaw) ?? .building).stringValue
    }

    public var points: [PersistedPointInput] {
        (try? JSONDecoder().decode([PersistedPointInput].self, from: pointsData)) ?? []
    }

    public var pois: [PersistedPoiInput] {
        (try? JSONDecoder().decode([PersistedPoiInput].self, from: poisData)) ?? []
    }

    public init(
        id: String, hash: String, totalDistanceMeters: Double, totalClimbingMeters: Double?, status: String,
        points: [PersistedPointInput], pois: [PersistedPoiInput]
    ) {
        self.id = id
        self.hash = hash
        self.totalDistanceMeters = totalDistanceMeters
        self.totalClimbingMeters = totalClimbingMeters
        self.statusRaw = CorridorStatusRaw(status).rawValue
        self.pointsData = (try? JSONEncoder().encode(points)) ?? Data()
        self.poisData = (try? JSONEncoder().encode(pois)) ?? Data()
    }
}

@MainActor
public enum RouteStore {
    public static func persist(
        routeId: String, hash: String, totalDistanceMeters: Double, totalClimbingMeters: Double?,
        points: [PersistedPointInput], pois: [PersistedPoiInput], status: String, context: ModelContext
    ) throws {
        let route = RouteModel(
            id: routeId, hash: hash, totalDistanceMeters: totalDistanceMeters,
            totalClimbingMeters: totalClimbingMeters, status: status, points: points, pois: pois)
        context.insert(route)
        try context.save()
    }
}

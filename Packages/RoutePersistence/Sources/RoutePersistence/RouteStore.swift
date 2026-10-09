import Foundation

/// File-backed JSON persistence for Route and CorridorPOI records (AC-29 in spec/criteria.md).
///
/// Was SwiftData-backed; replaced after a SwiftData crash
/// ("Could not cast value of type '__NSCFNumber' to 'NSString'") reproduced on multiple recent
/// iOS SDKs (27.0 locally, then 26.2 on GitHub's hosted CI runner — see
/// docs/known-issues/swiftdata-xcode27-model-crash.md) with no code-level workaround found
/// after extensive investigation, and GitHub-hosted runners don't offer a pinned-old-enough
/// simulator runtime to dodge it going forward. This is just a flat local cache of a handful of
/// routes and their POIs, with no relational querying need, so a single JSON file is a better
/// fit than fighting a persistence framework's own bugs.
public struct PersistedRoute: Codable, Sendable {
    public let id: String
    public let hash: String
    public let totalDistanceMeters: Double
    public let totalClimbingMeters: Double?
    public let status: String
    public let points: [PersistedPointInput]
    public let pois: [PersistedPoiInput]

    public init(
        id: String, hash: String, totalDistanceMeters: Double, totalClimbingMeters: Double?, status: String,
        points: [PersistedPointInput], pois: [PersistedPoiInput]
    ) {
        self.id = id
        self.hash = hash
        self.totalDistanceMeters = totalDistanceMeters
        self.totalClimbingMeters = totalClimbingMeters
        self.status = status
        self.points = points
        self.pois = pois
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

/// Serializes access to its backing JSON file (an actor, not a static utility) so concurrent
/// persist/fetch calls can't interleave reads and writes of the same file.
public actor RouteStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The real app's default store location, under Application Support.
    public static func defaultFileURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent("routes.json")
    }

    public func persist(
        routeId: String, hash: String, totalDistanceMeters: Double, totalClimbingMeters: Double?,
        points: [PersistedPointInput], pois: [PersistedPoiInput], status: String
    ) throws {
        var routesById = try loadAll()
        routesById[routeId] = PersistedRoute(
            id: routeId, hash: hash, totalDistanceMeters: totalDistanceMeters,
            totalClimbingMeters: totalClimbingMeters, status: status, points: points, pois: pois)
        let data = try JSONEncoder().encode(routesById)
        try data.write(to: fileURL, options: .atomic)
    }

    public func fetch(routeId: String) throws -> PersistedRoute? {
        try loadAll()[routeId]
    }

    public func fetchAll() throws -> [PersistedRoute] {
        Array(try loadAll().values)
    }

    private func loadAll() throws -> [String: PersistedRoute] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: PersistedRoute].self, from: data)
    }
}

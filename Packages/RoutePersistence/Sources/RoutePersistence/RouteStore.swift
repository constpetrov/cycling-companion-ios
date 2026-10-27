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
    /// The name shown on Home (milestone 7, RULE-26): from the GPX track or metadata name, else the
    /// file name. Local only; optional so routes saved by earlier builds still decode.
    public let displayName: String?
    /// The region the backend's stop data covers, and how much of this route lies outside it
    /// (milestone 8, RULE-20). Stored so the coverage message works offline; optional so routes
    /// saved by earlier builds still decode.
    public let coverageRegion: String?
    public let outsideMeters: Double?

    public init(
        id: String, hash: String, totalDistanceMeters: Double, totalClimbingMeters: Double?, status: String,
        points: [PersistedPointInput], pois: [PersistedPoiInput], displayName: String? = nil,
        coverageRegion: String? = nil, outsideMeters: Double? = nil
    ) {
        self.id = id
        self.hash = hash
        self.totalDistanceMeters = totalDistanceMeters
        self.totalClimbingMeters = totalClimbingMeters
        self.status = status
        self.points = points
        self.pois = pois
        self.displayName = displayName
        self.coverageRegion = coverageRegion
        self.outsideMeters = outsideMeters
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

/// One concrete weekly open window (RULE-32 in spec/rules.md), mirroring the backend's
/// `WeeklyOpenInterval` record field-for-field. `dayOfWeek` is ISO-8601 (1 = Monday..7 = Sunday).
public struct PersistedWeeklyOpenInterval: Codable, Sendable {
    public let dayOfWeek: Int
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int

    public init(dayOfWeek: Int, startMinuteOfDay: Int, endMinuteOfDay: Int) {
        self.dayOfWeek = dayOfWeek
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }
}

/// Mirrors the backend's `NormalizedOpeningHours` record field-for-field (RULE-32).
public struct PersistedNormalizedOpeningHours: Codable, Sendable {
    public let alwaysOpen: Bool
    public let unknown: Bool
    public let intervals: [PersistedWeeklyOpenInterval]

    public init(alwaysOpen: Bool, unknown: Bool, intervals: [PersistedWeeklyOpenInterval]) {
        self.alwaysOpen = alwaysOpen
        self.unknown = unknown
        self.intervals = intervals
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
    /// Optional, unlike the wire DTO it's sourced from: `RouteStore.fetchAll()` decodes
    /// whatever is already on disk, and a route cached before this field existed has no such
    /// key. `nil` is treated as "unknown" by POI Lookahead's lookup (RULE-17), consistent with
    /// the fail-open default for anything unparseable.
    public let normalizedOpeningHours: PersistedNormalizedOpeningHours?

    public init(
        osmId: Int64, type: String, name: String?, latitude: Double, longitude: Double,
        kmMarkMeters: Double, detourMeters: Double, openingHours: String?,
        normalizedOpeningHours: PersistedNormalizedOpeningHours? = nil
    ) {
        self.osmId = osmId
        self.type = type
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.kmMarkMeters = kmMarkMeters
        self.detourMeters = detourMeters
        self.openingHours = openingHours
        self.normalizedOpeningHours = normalizedOpeningHours
    }
}

/// Serializes access to its backing JSON file (an actor, not a static utility) so concurrent
/// persist/fetch calls can't interleave reads and writes of the same file.
public actor RouteStore {
    private let fileURL: URL
    /// The decoded file, kept after the first read (milestone 8 review): with complete stop data a
    /// route can carry thousands of stops (about 1.2 MB for a dense city route), and the ride reads
    /// its route every advisor cycle. Safe because each process has one `RouteStore` per file and
    /// every write goes through it.
    private var cache: [String: PersistedRoute]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The backing file, so tests can open a second store on it and check what reached disk.
    public nonisolated var fileURLForTests: URL { fileURL }

    /// The real app's default store location, under Application Support.
    public static func defaultFileURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent("routes.json")
    }

    /// `displayName: nil` keeps the name already stored for `routeId`, so status and stop updates
    /// never erase it; likewise `coverageRegion`/`outsideMeters: nil` keep the stored coverage.
    public func persist(
        routeId: String, hash: String, totalDistanceMeters: Double, totalClimbingMeters: Double?,
        points: [PersistedPointInput], pois: [PersistedPoiInput], status: String, displayName: String? = nil,
        coverageRegion: String? = nil, outsideMeters: Double? = nil
    ) throws {
        var routesById = try loadAll()
        let stored = routesById[routeId]
        routesById[routeId] = PersistedRoute(
            id: routeId, hash: hash, totalDistanceMeters: totalDistanceMeters,
            totalClimbingMeters: totalClimbingMeters, status: status, points: points, pois: pois,
            displayName: displayName ?? stored?.displayName,
            coverageRegion: coverageRegion ?? stored?.coverageRegion,
            outsideMeters: outsideMeters ?? stored?.outsideMeters)
        try write(routesById)
    }

    /// Changes one stored route's status — and its stops and coverage when given — in a single
    /// actor turn, so a concurrent write to the same route can't be lost between a read and a
    /// write (milestone 8 review). Does nothing if the route isn't stored.
    public func update(
        routeId: String, status: String, pois: [PersistedPoiInput]? = nil, coverageRegion: String? = nil,
        outsideMeters: Double? = nil
    ) throws {
        var routesById = try loadAll()
        guard let route = routesById[routeId] else { return }
        routesById[routeId] = PersistedRoute(
            id: routeId, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
            totalClimbingMeters: route.totalClimbingMeters, status: status, points: route.points,
            pois: pois ?? route.pois, displayName: route.displayName,
            coverageRegion: coverageRegion ?? route.coverageRegion, outsideMeters: outsideMeters ?? route.outsideMeters)
        try write(routesById)
    }

    private func write(_ routesById: [String: PersistedRoute]) throws {
        let data = try JSONEncoder().encode(routesById)
        try data.write(to: fileURL, options: .atomic)
        cache = routesById
    }

    /// Removes every stored route (milestone 10, RULE-38: sign-out and account deletion).
    public func deleteAll() throws {
        cache = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func fetch(routeId: String) throws -> PersistedRoute? {
        try loadAll()[routeId]
    }

    public func fetchAll() throws -> [PersistedRoute] {
        Array(try loadAll().values)
    }

    private func loadAll() throws -> [String: PersistedRoute] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let routes = try JSONDecoder().decode([String: PersistedRoute].self, from: data)
        cache = routes
        return routes
    }
}

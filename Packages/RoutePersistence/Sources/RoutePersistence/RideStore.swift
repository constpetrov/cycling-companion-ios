import Foundation

/// A single track sample (GPS + sensor) in a recorded ride (AC-18 in spec/criteria.md).
public struct PersistedRideSample: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let speedMetersPerSecond: Double
    public let heartRateBPM: Int?
    public let cadenceRPM: Int?
    public let timestamp: Date

    public init(
        latitude: Double, longitude: Double, speedMetersPerSecond: Double, heartRateBPM: Int?, cadenceRPM: Int?,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.speedMetersPerSecond = speedMetersPerSecond
        self.heartRateBPM = heartRateBPM
        self.cadenceRPM = cadenceRPM
        self.timestamp = timestamp
    }
}

/// A recorded (or in-progress) ride (AC-18/AC-19/AC-20 in spec/criteria.md). `endTime == nil`
/// signals "in progress, resumable" (RULE-12/RULE-13 in spec/rules.md) — the same type and
/// store serve both the incremental checkpoint and the final, completed record.
public struct PersistedRide: Codable, Sendable {
    public let id: String
    public let routeId: String
    public let startTime: Date
    public let endTime: Date?
    public let totalDistanceMeters: Double
    public let totalMovingTimeSeconds: Double
    public let track: [PersistedRideSample]
    /// The ride's stop suggestions and answers (RULE-17 in milestone 7's rules.md). Optional, so
    /// rides saved by earlier builds still decode.
    public let suggestionState: PersistedSuggestionState?

    public init(
        id: String, routeId: String, startTime: Date, endTime: Date?, totalDistanceMeters: Double,
        totalMovingTimeSeconds: Double, track: [PersistedRideSample], suggestionState: PersistedSuggestionState? = nil
    ) {
        self.id = id
        self.routeId = routeId
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistanceMeters = totalDistanceMeters
        self.totalMovingTimeSeconds = totalMovingTimeSeconds
        self.track = track
        self.suggestionState = suggestionState
    }
}

/// A stop suggestion as saved with its ride.
public struct PersistedSuggestion: Codable, Sendable, Equatable {
    public let id: String
    public let stopId: Int64
    public let name: String?
    public let type: String
    public let latitude: Double
    public let longitude: Double
    public let kmMarkMeters: Double
    public let detourMeters: Double
    public let message: String?
    public let suggestedAt: Date

    public init(
        id: String, stopId: Int64, name: String?, type: String, latitude: Double, longitude: Double,
        kmMarkMeters: Double, detourMeters: Double, message: String?, suggestedAt: Date
    ) {
        self.id = id
        self.stopId = stopId
        self.name = name
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
        self.kmMarkMeters = kmMarkMeters
        self.detourMeters = detourMeters
        self.message = message
        self.suggestedAt = suggestedAt
    }
}

/// The rider's answer to a suggestion as saved with its ride. `answer` is the wire value
/// (`ACCEPTED`, `DECLINED` or `NONE`).
public struct PersistedSuggestionAnswer: Codable, Sendable, Equatable {
    public let suggestionId: String
    public let stopId: Int64
    public let suggestedAt: Date
    public let answer: String
    public let respondedAt: Date?

    public init(suggestionId: String, stopId: Int64, suggestedAt: Date, answer: String, respondedAt: Date?) {
        self.suggestionId = suggestionId
        self.stopId = stopId
        self.suggestedAt = suggestedAt
        self.answer = answer
        self.respondedAt = respondedAt
    }
}

/// Everything needed to restore a ride's suggestion card, answers and declined stops on resume.
public struct PersistedSuggestionState: Codable, Sendable, Equatable {
    public let currentSuggestionId: String?
    public let suggestions: [PersistedSuggestion]
    public let answers: [PersistedSuggestionAnswer]
    public let declinedStopIds: [Int64]

    public init(
        currentSuggestionId: String?, suggestions: [PersistedSuggestion], answers: [PersistedSuggestionAnswer],
        declinedStopIds: [Int64]
    ) {
        self.currentSuggestionId = currentSuggestionId
        self.suggestions = suggestions
        self.answers = answers
        self.declinedStopIds = declinedStopIds
    }
}

/// File-backed JSON persistence for Ride records (RULE-2 in spec/rules.md) — mirrors
/// `RouteStore`'s exact pattern (RULE-18): a dictionary keyed by id, JSON-encoded and written
/// atomically to a single file. An actor, so concurrent persist/fetch calls (e.g. a checkpoint
/// write racing a resume read) can't interleave reads and writes of the same file.
public actor RideStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The real app's default store location, under Application Support.
    public static func defaultFileURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent("rides.json")
    }

    public func persist(_ ride: PersistedRide) throws {
        var ridesById = try loadAll()
        ridesById[ride.id] = ride
        let data = try JSONEncoder().encode(ridesById)
        try data.write(to: fileURL, options: .atomic)
    }

    public func fetch(rideId: String) throws -> PersistedRide? {
        try loadAll()[rideId]
    }

    public func fetchAll() throws -> [PersistedRide] {
        Array(try loadAll().values)
    }

    private func loadAll() throws -> [String: PersistedRide] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: PersistedRide].self, from: data)
    }
}

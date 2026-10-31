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

/// A stop suggestion as saved with its ride. `traceId` (milestone 9) is optional, so checkpoints
/// saved by earlier builds still decode.
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
    public let traceId: String?

    public init(
        id: String, stopId: Int64, name: String?, type: String, latitude: Double, longitude: Double,
        kmMarkMeters: Double, detourMeters: Double, message: String?, suggestedAt: Date, traceId: String? = nil
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
        self.traceId = traceId
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

/// One entry in a live ride's journal: the ride's totals at that moment and the samples new since
/// the previous entry. `firstSampleIndex` is where `samples` belong in the ride's track, so a batch
/// retried after a failed write replaces any part of it that did land rather than duplicating it.
public struct RideCheckpoint: Codable, Sendable {
    public let id: String
    public let routeId: String
    public let startTime: Date
    public let totalDistanceMeters: Double
    public let totalMovingTimeSeconds: Double
    public let firstSampleIndex: Int
    public let samples: [PersistedRideSample]
    public let suggestionState: PersistedSuggestionState?

    public init(
        id: String, routeId: String, startTime: Date, totalDistanceMeters: Double, totalMovingTimeSeconds: Double,
        firstSampleIndex: Int, samples: [PersistedRideSample], suggestionState: PersistedSuggestionState?
    ) {
        self.id = id
        self.routeId = routeId
        self.startTime = startTime
        self.totalDistanceMeters = totalDistanceMeters
        self.totalMovingTimeSeconds = totalMovingTimeSeconds
        self.firstSampleIndex = firstSampleIndex
        self.samples = samples
        self.suggestionState = suggestionState
    }
}

/// File-backed JSON persistence for Ride records (RULE-2 in spec/rules.md) — mirrors
/// `RouteStore`'s exact pattern (RULE-18): a dictionary keyed by id, JSON-encoded and written
/// atomically to a single file. An actor, so concurrent persist/fetch calls (e.g. a checkpoint
/// write racing a resume read) can't interleave reads and writes of the same file.
///
/// A live ride's checkpoints don't go in that file: rewriting every past ride on each checkpoint
/// cost more the longer the history got. They're appended to the ride's own journal instead, one
/// JSON line per checkpoint, and reads merge the journal in, so callers still see one unfinished
/// `PersistedRide`. `persist` supersedes the journal.
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
        var ridesById = try loadStored()
        ridesById[ride.id] = ride
        let data = try JSONEncoder().encode(ridesById)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.removeItem(at: journalURL(rideId: ride.id))
    }

    /// Appends a checkpoint to the ride's journal. Its cost doesn't depend on how many rides are
    /// stored. The surrounding newlines keep a line cut short by a failed write from running into
    /// the next one; a line that doesn't parse is skipped when the journal is read.
    public func appendCheckpoint(_ checkpoint: RideCheckpoint) throws {
        var line = Data([Self.newline])
        line.append(try JSONEncoder().encode(checkpoint))
        line.append(Self.newline)

        let url = journalURL(rideId: checkpoint.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            try line.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Removes one ride (milestone 7, RULE-27: discarding an unfinished ride that can't be resumed).
    public func delete(rideId: String) throws {
        try? FileManager.default.removeItem(at: journalURL(rideId: rideId))
        var ridesById = try loadStored()
        guard ridesById.removeValue(forKey: rideId) != nil else { return }
        let data = try JSONEncoder().encode(ridesById)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Removes every ride, finished or checkpointed (milestone 10, RULE-38).
    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: journalDirectory.path) {
            try FileManager.default.removeItem(at: journalDirectory)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func fetch(rideId: String) throws -> PersistedRide? {
        try loadAll()[rideId]
    }

    public func fetchAll() throws -> [PersistedRide] {
        Array(try loadAll().values)
    }

    private static let newline = UInt8(ascii: "\n")

    private var journalDirectory: URL {
        fileURL.deletingPathExtension().appendingPathExtension("live")
    }

    private func journalURL(rideId: String) -> URL {
        let fileName = rideId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rideId
        return journalDirectory.appendingPathComponent(fileName + ".ndjson")
    }

    private func loadStored() throws -> [String: PersistedRide] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: PersistedRide].self, from: data)
    }

    private func loadAll() throws -> [String: PersistedRide] {
        var ridesById = try loadStored()
        let journals = (try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)) ?? []
        for journal in journals {
            let decoder = JSONDecoder()
            let checkpoints = try Data(contentsOf: journal)
                .split(separator: Self.newline)
                .compactMap { try? decoder.decode(RideCheckpoint.self, from: Data($0)) }
            guard let latest = checkpoints.last else { continue }
            // A checkpoint saved by an earlier build is the start of the track; the journal continues it.
            let stored = ridesById[latest.id]
            if stored?.endTime != nil {
                // The app stopped between saving the finished ride and removing its journal.
                try? FileManager.default.removeItem(at: journal)
                continue
            }
            var track = stored?.track ?? []
            for checkpoint in checkpoints {
                track.replaceSubrange(min(checkpoint.firstSampleIndex, track.count)..., with: checkpoint.samples)
            }
            ridesById[latest.id] = PersistedRide(
                id: latest.id, routeId: latest.routeId, startTime: latest.startTime, endTime: nil,
                totalDistanceMeters: latest.totalDistanceMeters, totalMovingTimeSeconds: latest.totalMovingTimeSeconds,
                track: track, suggestionState: latest.suggestionState)
        }
        return ridesById
    }
}

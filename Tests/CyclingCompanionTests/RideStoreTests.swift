import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-1.4 validation: PersistedRide/RideStore round-trip persist+fetch, including a
/// zero-moving-time record (AC-19) and an in-progress (no endTime) record.
final class RideStoreTests: XCTestCase {

    private func tempStoreFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    func testPersistAndFetchRoundTripsACompletedRide() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let ride = PersistedRide(
            id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 3600), totalDistanceMeters: 30_000, totalMovingTimeSeconds: 3600,
            track: [
                PersistedRideSample(
                    latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 8.0, heartRateBPM: 140, cadenceRPM: 85,
                    timestamp: Date(timeIntervalSince1970: 0))
            ])

        try await store.persist(ride)
        let fetched = try await store.fetch(rideId: "ride-1")

        XCTAssertEqual(fetched?.id, ride.id)
        XCTAssertEqual(fetched?.endTime, ride.endTime)
        XCTAssertEqual(fetched?.totalDistanceMeters, ride.totalDistanceMeters)
        XCTAssertEqual(fetched?.track.count, 1)
        XCTAssertEqual(fetched?.track.first?.heartRateBPM, 140)
    }

    func testPersistAndFetchRoundTripsAnInProgressRideWithNoEndTime() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let ride = PersistedRide(
            id: "ride-2", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
            totalDistanceMeters: 500, totalMovingTimeSeconds: 120, track: [])

        try await store.persist(ride)
        let fetched = try await store.fetch(rideId: "ride-2")

        XCTAssertNotNil(fetched)
        XCTAssertNil(fetched?.endTime)
    }

    /// AC-19: a ride ended with zero or near-zero moving time still persists a valid record.
    func testRideWithZeroMovingTimeAndDistanceRoundTripsCleanly() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let ride = PersistedRide(
            id: "ride-3", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 1), totalDistanceMeters: 0, totalMovingTimeSeconds: 0, track: [])

        try await store.persist(ride)
        let fetched = try await store.fetch(rideId: "ride-3")

        XCTAssertEqual(fetched?.totalDistanceMeters, 0)
        XCTAssertEqual(fetched?.totalMovingTimeSeconds, 0)
        XCTAssertEqual(fetched?.track.count, 0)
    }

    func testFetchAllReturnsEveryPersistedRide() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        try await store.persist(
            PersistedRide(
                id: "a", routeId: "r", startTime: Date(), endTime: nil, totalDistanceMeters: 0,
                totalMovingTimeSeconds: 0, track: []))
        try await store.persist(
            PersistedRide(
                id: "b", routeId: "r", startTime: Date(), endTime: Date(), totalDistanceMeters: 100,
                totalMovingTimeSeconds: 10, track: []))

        let all = try await store.fetchAll()

        XCTAssertEqual(all.count, 2)
    }

    // MARK: - Live ride journal

    private func sample(_ second: Int) -> PersistedRideSample {
        PersistedRideSample(
            latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, heartRateBPM: nil, cadenceRPM: nil,
            timestamp: Date(timeIntervalSince1970: TimeInterval(second)))
    }

    private func checkpoint(
        id: String = "live", distance: Double = 100, first: Int, seconds: [Int], suggestionState: PersistedSuggestionState? = nil
    ) -> RideCheckpoint {
        RideCheckpoint(
            id: id, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), totalDistanceMeters: distance,
            totalMovingTimeSeconds: 10, firstSampleIndex: first, samples: seconds.map(sample),
            suggestionState: suggestionState)
    }

    private func journalURL(_ fileURL: URL, rideId: String = "live") -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("live").appendingPathComponent(rideId + ".ndjson")
    }

    private func seconds(_ ride: PersistedRide?) -> [Int]? {
        ride?.track.map { Int($0.timestamp.timeIntervalSince1970) }
    }

    func testCheckpointsReadBackAsOneUnfinishedRide() async throws {
        let store = RideStore(fileURL: tempStoreFileURL())
        let state = PersistedSuggestionState(currentSuggestionId: "s", suggestions: [], answers: [], declinedStopIds: [7])

        try await store.appendCheckpoint(checkpoint(distance: 100, first: 0, seconds: [1, 2]))
        try await store.appendCheckpoint(checkpoint(distance: 200, first: 2, seconds: [3], suggestionState: state))

        let ride = try await store.fetch(rideId: "live")
        XCTAssertNil(ride?.endTime)
        XCTAssertEqual(ride?.routeId, "route-1")
        XCTAssertEqual(ride?.totalDistanceMeters, 200, "the latest checkpoint's totals win")
        XCTAssertEqual(seconds(ride), [1, 2, 3])
        XCTAssertEqual(ride?.suggestionState?.declinedStopIds, [7])
        let all = try await store.fetchAll()
        XCTAssertEqual(all.first(where: { $0.endTime == nil })?.id, "live")
    }

    func testACheckpointDoesNotRewriteTheFinishedRides() async throws {
        let fileURL = tempStoreFileURL()
        let store = RideStore(fileURL: fileURL)
        try await store.persist(
            PersistedRide(
                id: "past", routeId: "r", startTime: Date(), endTime: Date(), totalDistanceMeters: 1,
                totalMovingTimeSeconds: 1, track: [sample(0)]))
        let before = try Data(contentsOf: fileURL)

        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1]))

        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 2)
    }

    func testALineCutShortByAKilledWriteIsSkippedAndTheNextOneStillReads() async throws {
        let fileURL = tempStoreFileURL()
        let store = RideStore(fileURL: fileURL)
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1]))
        let handle = try FileHandle(forWritingTo: journalURL(fileURL))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"live","routeId":"rou"#.utf8))
        try handle.close()

        let afterCut = try await store.fetch(rideId: "live")
        XCTAssertEqual(seconds(afterCut), [1])

        try await store.appendCheckpoint(checkpoint(first: 1, seconds: [2]))
        let afterNext = try await store.fetch(rideId: "live")
        XCTAssertEqual(seconds(afterNext), [1, 2])
    }

    func testARetriedBatchDoesNotDuplicateSamples() async throws {
        let store = RideStore(fileURL: tempStoreFileURL())
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1, 2]))
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1, 2, 3]))

        let ride = try await store.fetch(rideId: "live")
        XCTAssertEqual(seconds(ride), [1, 2, 3])
    }

    func testACheckpointFromAnEarlierBuildIsContinuedByTheJournal() async throws {
        let store = RideStore(fileURL: tempStoreFileURL())
        try await store.persist(
            PersistedRide(
                id: "live", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 50, totalMovingTimeSeconds: 5, track: [sample(1), sample(2)]))

        try await store.appendCheckpoint(checkpoint(distance: 300, first: 2, seconds: [3]))

        let ride = try await store.fetch(rideId: "live")
        XCTAssertEqual(ride?.totalDistanceMeters, 300)
        XCTAssertEqual(seconds(ride), [1, 2, 3])
    }

    func testFinishingARideSupersedesItsJournal() async throws {
        let fileURL = tempStoreFileURL()
        let store = RideStore(fileURL: fileURL)
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1]))

        try await store.persist(
            PersistedRide(
                id: "live", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: Date(),
                totalDistanceMeters: 999, totalMovingTimeSeconds: 10, track: [sample(1), sample(2)]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL(fileURL).path))
        let ride = try await store.fetch(rideId: "live")
        XCTAssertEqual(ride?.totalDistanceMeters, 999)
        XCTAssertEqual(seconds(ride), [1, 2])
    }

    /// The app stopped between saving the finished ride and removing its journal.
    func testAJournalLeftBehindCannotReopenAFinishedRide() async throws {
        let fileURL = tempStoreFileURL()
        let store = RideStore(fileURL: fileURL)
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1]))
        let journal = try Data(contentsOf: journalURL(fileURL))
        try await store.persist(
            PersistedRide(
                id: "live", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: Date(),
                totalDistanceMeters: 999, totalMovingTimeSeconds: 10, track: [sample(1)]))
        try journal.write(to: journalURL(fileURL))

        let ride = try await store.fetch(rideId: "live")

        XCTAssertNotNil(ride?.endTime)
        XCTAssertEqual(ride?.totalDistanceMeters, 999)
    }

    func testDeletingARideRemovesItsJournal() async throws {
        let store = RideStore(fileURL: tempStoreFileURL())
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1]))

        try await store.delete(rideId: "live")

        let ride = try await store.fetch(rideId: "live")
        XCTAssertNil(ride)
    }

    func testDeleteAllRemovesLiveRidesToo() async throws {
        let store = RideStore(fileURL: tempStoreFileURL())
        try await store.appendCheckpoint(checkpoint(first: 0, seconds: [1]))

        try await store.deleteAll()

        let all = try await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }
}

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
}

import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.5 validation (RULE-11, AC-18): `RideRecorder.finalize` persists a completed
/// `PersistedRide` with `endTime` set and the full track/stats.
final class RideRecorderTests: XCTestCase {

    private func tempStoreFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    func testFinalizePersistsACompletedRideWithEndTimeAndFullStats() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        let recorder = RideRecorder(rideStore: store)
        let track = [
            PersistedRideSample(
                latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, heartRateBPM: 140, cadenceRPM: 85,
                timestamp: Date(timeIntervalSince1970: 0))
        ]

        try await recorder.finalize(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 3_600), totalDistanceMeters: 30_000, totalMovingTimeSeconds: 3_500,
            track: track)

        let persisted = try await store.fetch(rideId: "ride-1")
        XCTAssertEqual(persisted?.endTime, Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(persisted?.totalDistanceMeters, 30_000)
        XCTAssertEqual(persisted?.totalMovingTimeSeconds, 3_500)
        XCTAssertEqual(persisted?.track.count, 1)
        XCTAssertEqual(persisted?.track.first?.heartRateBPM, 140)
        XCTAssertEqual(persisted?.track.first?.cadenceRPM, 85)
    }

    /// Simulates RideTracker's last mid-ride checkpoint (RULE-12) followed by RideRecorder's
    /// final write (RULE-11) for the same id — the final write must supersede the checkpoint.
    func testFinalizeSupersedesAPriorInProgressCheckpointForTheSameRide() async throws {
        let fileURL = tempStoreFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = RideStore(fileURL: fileURL)
        try await store.persist(
            PersistedRide(
                id: "ride-2", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 500, totalMovingTimeSeconds: 120, track: []))
        let recorder = RideRecorder(rideStore: store)

        try await recorder.finalize(
            rideId: "ride-2", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 600), totalDistanceMeters: 5_000, totalMovingTimeSeconds: 590,
            track: [])

        let persisted = try await store.fetch(rideId: "ride-2")
        XCTAssertNotNil(persisted?.endTime, "the checkpoint's nil endTime must be superseded by the final write")
        XCTAssertEqual(persisted?.totalDistanceMeters, 5_000)
    }
}

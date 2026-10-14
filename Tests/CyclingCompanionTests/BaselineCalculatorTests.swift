import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-1.1 validation (RULE-1/RULE-3/RULE-4 in spec/rules.md, AC-1/AC-2/AC-3).
final class BaselineCalculatorTests: XCTestCase {

    private func finishedRide(distanceMeters: Double, movingTimeSeconds: Double, id: String = UUID().uuidString)
        -> PersistedRide
    {
        PersistedRide(
            id: id, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: movingTimeSeconds), totalDistanceMeters: distanceMeters,
            totalMovingTimeSeconds: movingTimeSeconds, track: [])
    }

    private func unfinishedRide() -> PersistedRide {
        PersistedRide(
            id: UUID().uuidString, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
            totalDistanceMeters: 1_000, totalMovingTimeSeconds: 100, track: [])
    }

    func testFewerThanFiveFinishedRidesReturnsNil() {
        let rides = (0..<4).map { _ in finishedRide(distanceMeters: 20_000, movingTimeSeconds: 3_600) }

        XCTAssertNil(BaselineCalculator.compute(from: rides))
    }

    func testExactlyFiveFinishedRidesReturnsBaselines() throws {
        let rides = (0..<5).map { _ in finishedRide(distanceMeters: 20_000, movingTimeSeconds: 3_600) }

        let baselines = try XCTUnwrap(BaselineCalculator.compute(from: rides))

        XCTAssertEqual(baselines.averageMovingSpeedMetersPerSecond, 20_000 / 3_600, accuracy: 0.001)
        XCTAssertEqual(baselines.maximumDistanceMeters, 20_000)
    }

    func testMoreThanFiveFinishedRidesReturnsBaselines() {
        let rides = (0..<8).map { _ in finishedRide(distanceMeters: 20_000, movingTimeSeconds: 3_600) }

        XCTAssertNotNil(BaselineCalculator.compute(from: rides))
    }

    func testAverageSpeedIsComputedAcrossAllFinishedRides() throws {
        let rides = [
            finishedRide(distanceMeters: 10_000, movingTimeSeconds: 1_000),  // 10 m/s
            finishedRide(distanceMeters: 20_000, movingTimeSeconds: 2_000),  // 10 m/s
            finishedRide(distanceMeters: 30_000, movingTimeSeconds: 6_000),  // 5 m/s
            finishedRide(distanceMeters: 15_000, movingTimeSeconds: 1_500),  // 10 m/s
            finishedRide(distanceMeters: 5_000, movingTimeSeconds: 1_000),  // 5 m/s
        ]

        let baselines = try XCTUnwrap(BaselineCalculator.compute(from: rides))

        XCTAssertEqual(baselines.averageMovingSpeedMetersPerSecond, 8.0, accuracy: 0.001)
    }

    func testMaximumDistanceIsTheLargestFinishedRide() {
        let rides = [
            finishedRide(distanceMeters: 10_000, movingTimeSeconds: 1_000),
            finishedRide(distanceMeters: 50_000, movingTimeSeconds: 5_000),
            finishedRide(distanceMeters: 20_000, movingTimeSeconds: 2_000),
            finishedRide(distanceMeters: 15_000, movingTimeSeconds: 1_500),
            finishedRide(distanceMeters: 5_000, movingTimeSeconds: 500),
        ]

        let baselines = BaselineCalculator.compute(from: rides)

        XCTAssertEqual(baselines?.maximumDistanceMeters, 50_000)
    }

    func testUnfinishedRidesAreExcludedFromTheFloorAndTheComputation() {
        var rides = (0..<5).map { _ in finishedRide(distanceMeters: 20_000, movingTimeSeconds: 3_600) }
        rides.append(unfinishedRide())
        rides.append(unfinishedRide())

        // Still exactly 5 finished rides despite 7 total rows — the unfinished ones must not
        // count toward the floor or skew the computation.
        let baselines = BaselineCalculator.compute(from: rides)

        XCTAssertNotNil(baselines)
        XCTAssertEqual(baselines?.maximumDistanceMeters, 20_000)
    }

    @MainActor
    func testComputeFromRideStoreReadsLocalHistory() async {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        for _ in 0..<5 {
            try? await rideStore.persist(
                PersistedRide(
                    id: UUID().uuidString, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
                    endTime: Date(timeIntervalSince1970: 3_600), totalDistanceMeters: 20_000,
                    totalMovingTimeSeconds: 3_600, track: []))
        }

        let baselines = await BaselineCalculator.compute(from: rideStore)

        XCTAssertNotNil(baselines)
    }

    @MainActor
    func testComputeFromAnEmptyRideStoreReturnsNil() async {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))

        let baselines = await BaselineCalculator.compute(from: rideStore)

        XCTAssertNil(baselines)
    }
}

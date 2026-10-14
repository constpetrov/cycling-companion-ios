import RoutePersistence
import UserNotifications
import XCTest

@testable import CyclingCompanion

/// task-2.3 validation (RULE-8/RULE-9/RULE-10/RULE-11 in spec/rules.md, AC-7 through AC-13).
final class RideOutcomeCalculatorTests: XCTestCase {

    private func notification(stopId: String, latitude: Double, longitude: Double) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.userInfo = ["stopId": stopId, "latitude": latitude, "longitude": longitude]
        return UNNotificationRequest(identifier: stopId, content: content, trigger: nil)
    }

    private func sample(latitude: Double, longitude: Double) -> PersistedRideSample {
        PersistedRideSample(
            latitude: latitude, longitude: longitude, speedMetersPerSecond: 5, heartRateBPM: nil, cadenceRPM: nil,
            timestamp: Date(timeIntervalSince1970: 0))
    }

    // MARK: - stopsTaken (AC-7/AC-8/AC-9/AC-10)

    func testAFixWithinTheRadiusCountsAsStopped() {
        // ~70m north of the stop (roughly 0.00063 degrees latitude).
        let notifications = [notification(stopId: "1", latitude: 52.0, longitude: 13.0)]
        let track = [sample(latitude: 52.00063, longitude: 13.0)]

        XCTAssertEqual(RideOutcomeCalculator.stopsTaken(postedNotifications: notifications, track: track), 1)
    }

    func testExactlyAtTheRadiusBoundaryCountsAsWithinRadius() {
        // Geometric computation can't reliably land on the literal floating-point value
        // 100.0, so the inclusive-boundary comparison itself (RULE-9) is tested directly.
        XCTAssertTrue(RideOutcomeCalculator.isWithinStopRadius(distanceMeters: 100.0))
    }

    func testBeyondTheRadiusBoundaryIsNotWithinRadius() {
        XCTAssertFalse(RideOutcomeCalculator.isWithinStopRadius(distanceMeters: 100.001))
    }

    func testAFixBeyondTheRadiusDoesNotCountAsStopped() {
        // ~1,100m north of the stop.
        let notifications = [notification(stopId: "1", latitude: 52.0, longitude: 13.0)]
        let track = [sample(latitude: 52.01, longitude: 13.0)]

        XCTAssertEqual(RideOutcomeCalculator.stopsTaken(postedNotifications: notifications, track: track), 0)
    }

    func testZeroApprovedSuggestionsYieldsZeroStopsTaken() {
        XCTAssertEqual(RideOutcomeCalculator.stopsTaken(postedNotifications: [], track: [sample(latitude: 52, longitude: 13)]), 0)
    }

    func testAZeroZeroCoordinateNotificationIsNeverCountedAsStopped() {
        let notifications = [notification(stopId: "1", latitude: 0, longitude: 0)]
        // A real fix that happens to be near (0, 0) — must still not count, since (0, 0) is
        // Notifier's own "unmatched candidate" fallback, never a real stop.
        let track = [sample(latitude: 0.0001, longitude: 0.0001)]

        XCTAssertEqual(RideOutcomeCalculator.stopsTaken(postedNotifications: notifications, track: track), 0)
    }

    func testMultipleApprovedSuggestionsAreCountedIndependently() {
        let notifications = [
            notification(stopId: "1", latitude: 52.0, longitude: 13.0),
            notification(stopId: "2", latitude: 53.0, longitude: 14.0),
        ]
        // Only the first stop was actually visited.
        let track = [sample(latitude: 52.0, longitude: 13.0)]

        XCTAssertEqual(RideOutcomeCalculator.stopsTaken(postedNotifications: notifications, track: track), 1)
    }

    // MARK: - outcome (AC-11/AC-12/AC-13)

    private func finishedRide(distanceMeters: Double) -> PersistedRide {
        PersistedRide(
            id: UUID().uuidString, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 3_600), totalDistanceMeters: distanceMeters,
            totalMovingTimeSeconds: 3_600, track: [])
    }

    func testARideWithinTwentyPercentOfAverageIsTypical() {
        let history = [finishedRide(distanceMeters: 20_000), finishedRide(distanceMeters: 20_000)]

        let outcome = RideOutcomeCalculator.outcome(thisRideDistanceMeters: 22_000, historicalRides: history)

        XCTAssertEqual(outcome, .typical)
    }

    func testARideMoreThanTwentyPercentOverAverageIsLonger() {
        let history = [finishedRide(distanceMeters: 20_000), finishedRide(distanceMeters: 20_000)]

        let outcome = RideOutcomeCalculator.outcome(thisRideDistanceMeters: 30_000, historicalRides: history)

        XCTAssertEqual(outcome, .longerThanUsual)
    }

    func testARideMoreThanTwentyPercentUnderAverageIsShorter() {
        let history = [finishedRide(distanceMeters: 20_000), finishedRide(distanceMeters: 20_000)]

        let outcome = RideOutcomeCalculator.outcome(thisRideDistanceMeters: 10_000, historicalRides: history)

        XCTAssertEqual(outcome, .shorterThanUsual)
    }

    func testNoHistoricalRidesReadsAsTypical() {
        let outcome = RideOutcomeCalculator.outcome(thisRideDistanceMeters: 20_000, historicalRides: [])

        XCTAssertEqual(outcome, .typical)
    }
}

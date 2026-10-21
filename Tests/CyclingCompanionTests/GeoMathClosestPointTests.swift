import XCTest

@testable import CyclingCompanion

/// task-1.3 validation: the 50 m corridor boundary (within / at / beyond), matching
/// AC-2/AC-3/AC-4's three-point pattern. Pure function, no RideTracker involved.
final class GeoMathClosestPointTests: XCTestCase {

    private func loop() -> [ResampledPoint] {
        [(52.0, 13.0), (52.0, 13.01), (52.01, 13.01), (52.01, 13.0), (52.0, 13.0)]
            .enumerated().map { index, coordinate in
                ResampledPoint(
                    latitude: coordinate.0, longitude: coordinate.1, elevationMeters: nil,
                    cumulativeDistanceMeters: Double(index) * 1_000)
            }
    }

    func testSharedStartFinishMatchesFinishWhenProgressIsNearFinish() {
        let result = GeoMath.closestPointOnRoute(
            latitude: 52, longitude: 13, route: loop(), progressRange: 3_800...4_000)
        XCTAssertEqual(result.distanceAlongRouteMeters, 4_000, accuracy: 0.01)
        XCTAssertEqual(result.offRouteMeters, 0, accuracy: 0.01)
    }

    func testGpsNoiseNearStartDoesNotMatchFinishBranch() {
        let result = GeoMath.closestPointOnRoute(
            latitude: 52.00001, longitude: 13, route: loop(), progressRange: 0...100)
        XCTAssertEqual(result.distanceAlongRouteMeters, 0, accuracy: 0.01)
        XCTAssertLessThan(result.offRouteMeters, 50)
    }

    func testReachableRangeAllowsBacktracking() {
        let result = GeoMath.closestPointOnRoute(
            latitude: 52, longitude: 13.004, route: loop(), progressRange: 300...700)
        XCTAssertEqual(result.distanceAlongRouteMeters, 400, accuracy: 0.01)
    }

    func testUnreachableBranchDoesNotProduceAnAcceptedMatch() {
        let result = GeoMath.closestPointOnRoute(
            latitude: 52, longitude: 13, route: loop(), progressRange: 1_500...2_500)
        XCTAssertGreaterThan(result.offRouteMeters, 50)
    }

    /// An east-west segment at a fixed latitude, so a pure north offset from its midpoint is
    /// exactly the perpendicular (off-route) distance under the same equirectangular
    /// approximation `closestPointOnRoute` itself uses — no floating-point-approximation
    /// mismatch between test expectation and implementation.
    private let segmentEnd = 1_000.0

    private func route() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.01, elevationMeters: nil, cumulativeDistanceMeters: segmentEnd),
        ]
    }

    private func queryPoint(northOffsetMeters: Double) -> (latitude: Double, longitude: Double) {
        let dLatRadians = northOffsetMeters / GeoMath.earthRadiusMeters
        let latitude = 52.0 + dLatRadians * 180 / .pi
        return (latitude, 13.005) // route's midpoint longitude
    }

    func testPointWithinFiftyMetersReportsMatchingOffRouteDistance() {
        let point = queryPoint(northOffsetMeters: 10)
        let result = GeoMath.closestPointOnRoute(latitude: point.latitude, longitude: point.longitude, route: route())

        XCTAssertEqual(result.offRouteMeters, 10, accuracy: 0.01)
        XCTAssertEqual(result.distanceAlongRouteMeters, segmentEnd / 2, accuracy: 1.0)
    }

    func testPointExactlyAtFiftyMetersReportsMatchingOffRouteDistance() {
        let point = queryPoint(northOffsetMeters: 50)
        let result = GeoMath.closestPointOnRoute(latitude: point.latitude, longitude: point.longitude, route: route())

        XCTAssertEqual(result.offRouteMeters, 50, accuracy: 0.01)
        XCTAssertEqual(result.distanceAlongRouteMeters, segmentEnd / 2, accuracy: 1.0)
    }

    func testPointBeyondFiftyMetersReportsOffRouteDistanceOverTheBoundary() {
        let point = queryPoint(northOffsetMeters: 51)
        let result = GeoMath.closestPointOnRoute(latitude: point.latitude, longitude: point.longitude, route: route())

        XCTAssertEqual(result.offRouteMeters, 51, accuracy: 0.01)
        XCTAssertGreaterThan(result.offRouteMeters, 50)
    }
}

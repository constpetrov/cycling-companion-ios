import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// AC-42 to AC-46 in milestone 8's criteria.md (RULE-20).
final class CoverageMessageTests: XCTestCase {

    private func text(_ outside: Double?, of length: Double = 100_000, region: String? = "Netherlands") -> String? {
        CoverageMessage.text(outsideMeters: outside, routeLengthMeters: length, regionName: region)
    }

    /// AC-42.
    func testPartlyOutsideRoundsToTheNearestKilometre() {
        XCTAssertEqual(text(12_400), "Stops are only available in the Netherlands — 12 km of this route are outside")
        XCTAssertEqual(text(12_600), "Stops are only available in the Netherlands — 13 km of this route are outside")
    }

    /// AC-43.
    func testUnderOneKilometreShowsOne() {
        XCTAssertEqual(text(300), "Stops are only available in the Netherlands — 1 km of this route are outside")
    }

    /// AC-44.
    func testEntirelyOutside() {
        XCTAssertEqual(text(100_000), "This route is outside the area we have stops for")
        XCTAssertEqual(text(99_960), "This route is outside the area we have stops for", "within the 50 m tolerance")
    }

    /// AC-45.
    func testEntirelyInsideShowsNothing() {
        XCTAssertNil(text(0))
    }

    /// AC-46.
    func testUnknownCoverageShowsNothing() {
        XCTAssertNil(text(nil))
    }

    func testAStoredRouteFeedsTheMessage() {
        let route = PersistedRoute(
            id: "r", hash: "h", totalDistanceMeters: 40_000, totalClimbingMeters: nil, status: "ready", points: [],
            pois: [], coverageRegion: "Netherlands", outsideMeters: 5_200)

        XCTAssertEqual(CoverageMessage.text(for: route), "Stops are only available in the Netherlands — 5 km of this route are outside")
        XCTAssertEqual(RouteCard(route: route, isPolling: false, locale: Locale(identifier: "en_US")).coverageText,
                       CoverageMessage.text(for: route))
    }
}

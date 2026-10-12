import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-1.4 validation (RULE-18 in spec/rules.md): the 30 km lookahead boundary (within/at/
/// beyond, AC-21/22/23) and the 5-candidate cap (fewer/exactly/more than 5, AC-18/19/20).
/// Opening-hours exclusion is a separate step (task-1.5) — every POI here is a plain candidate.
final class POILookaheadTests: XCTestCase {

    private func poi(osmId: Int64, kmMarkMeters: Double, detourMeters: Double = 100) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: "POI \(osmId)", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: kmMarkMeters, detourMeters: detourMeters, openingHours: nil)
    }

    // MARK: - Lookahead range boundary (AC-21/AC-22/AC-23)

    func testStopWithinLookaheadRangeIsIncluded() {
        let candidate = poi(osmId: 1, kmMarkMeters: 10_000_000 + 20_000)
        let result = POILookahead.rankedCandidates(pois: [candidate], currentKmMarkMeters: 10_000_000)

        XCTAssertEqual(result.map(\.osmId), [1])
    }

    func testStopExactlyAtLookaheadBoundaryIsIncluded() {
        let candidate = poi(osmId: 1, kmMarkMeters: 10_000_000 + POILookahead.lookaheadMeters)
        let result = POILookahead.rankedCandidates(pois: [candidate], currentKmMarkMeters: 10_000_000)

        XCTAssertEqual(result.map(\.osmId), [1])
    }

    func testStopBeyondLookaheadRangeIsExcluded() {
        let candidate = poi(osmId: 1, kmMarkMeters: 10_000_000 + POILookahead.lookaheadMeters + 1)
        let result = POILookahead.rankedCandidates(pois: [candidate], currentKmMarkMeters: 10_000_000)

        XCTAssertTrue(result.isEmpty)
    }

    func testStopBehindTheCurrentKmMarkIsExcluded() {
        let candidate = poi(osmId: 1, kmMarkMeters: 9_999_000)
        let result = POILookahead.rankedCandidates(pois: [candidate], currentKmMarkMeters: 10_000_000)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Candidate cap (AC-18/AC-19/AC-20)

    func testFewerThanFiveCandidatesReturnsAllOfThem() {
        let pois = (1...3).map { poi(osmId: Int64($0), kmMarkMeters: 1_000 * Double($0)) }
        let result = POILookahead.rankedCandidates(pois: pois, currentKmMarkMeters: 0)

        XCTAssertEqual(result.count, 3)
    }

    func testExactlyFiveCandidatesReturnsAllFive() {
        let pois = (1...5).map { poi(osmId: Int64($0), kmMarkMeters: 1_000 * Double($0)) }
        let result = POILookahead.rankedCandidates(pois: pois, currentKmMarkMeters: 0)

        XCTAssertEqual(result.count, 5)
    }

    func testMoreThanFiveCandidatesReturnsOnlyTheFiveWithTheSmallestDetour() {
        // 6 candidates, all within range, with distinct, clearly-ordered detours — the 5
        // smallest-detour ones (osmId 1-5) must be returned, not osmId 6 (the largest detour).
        let pois = (1...6).map { poi(osmId: Int64($0), kmMarkMeters: 1_000, detourMeters: Double($0) * 10) }
        let result = POILookahead.rankedCandidates(pois: pois, currentKmMarkMeters: 0)

        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(Set(result.map(\.osmId)), Set(1...5))
        XCTAssertFalse(result.map(\.osmId).contains(6))
    }

    // MARK: - Closed-at-ETA exclusion (AC-24)

    private func poi(
        osmId: Int64, kmMarkMeters: Double, normalizedOpeningHours: PersistedNormalizedOpeningHours?
    ) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: "POI \(osmId)", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: kmMarkMeters, detourMeters: 100, openingHours: nil,
            normalizedOpeningHours: normalizedOpeningHours)
    }

    /// Monday (ISO day 1), 10:00 (minute 600).
    private let mondayTenAM = (dayOfWeek: 1, minuteOfDay: 600)

    func testStopConfirmedClosedAtETAIsExcluded() {
        let hours = PersistedNormalizedOpeningHours(
            alwaysOpen: false, unknown: false,
            intervals: [PersistedWeeklyOpenInterval(dayOfWeek: 1, startMinuteOfDay: 720, endMinuteOfDay: 1080)])
        let candidate = poi(osmId: 1, kmMarkMeters: 1_000, normalizedOpeningHours: hours)

        let result = POILookahead.candidates(
            pois: [candidate], currentKmMarkMeters: 0, etaDayOfWeek: mondayTenAM.dayOfWeek,
            etaMinuteOfDay: mondayTenAM.minuteOfDay)

        XCTAssertTrue(result.isEmpty, "10:00 is before the 12:00-18:00 window, so this stop is confirmed closed")
    }

    func testStopOpenAtETAIsNotExcluded() {
        let hours = PersistedNormalizedOpeningHours(
            alwaysOpen: false, unknown: false,
            intervals: [PersistedWeeklyOpenInterval(dayOfWeek: 1, startMinuteOfDay: 480, endMinuteOfDay: 1080)])
        let candidate = poi(osmId: 1, kmMarkMeters: 1_000, normalizedOpeningHours: hours)

        let result = POILookahead.candidates(
            pois: [candidate], currentKmMarkMeters: 0, etaDayOfWeek: mondayTenAM.dayOfWeek,
            etaMinuteOfDay: mondayTenAM.minuteOfDay)

        XCTAssertEqual(result.map(\.osmId), [1])
    }

    func testStopWithUnknownHoursIsNotExcluded() {
        let hours = PersistedNormalizedOpeningHours(alwaysOpen: false, unknown: true, intervals: [])
        let candidate = poi(osmId: 1, kmMarkMeters: 1_000, normalizedOpeningHours: hours)

        let result = POILookahead.candidates(
            pois: [candidate], currentKmMarkMeters: 0, etaDayOfWeek: mondayTenAM.dayOfWeek,
            etaMinuteOfDay: mondayTenAM.minuteOfDay)

        XCTAssertEqual(result.map(\.osmId), [1])
    }

    func testStopMarkedAlwaysOpenIsNotExcluded() {
        let hours = PersistedNormalizedOpeningHours(alwaysOpen: true, unknown: false, intervals: [])
        let candidate = poi(osmId: 1, kmMarkMeters: 1_000, normalizedOpeningHours: hours)

        let result = POILookahead.candidates(
            pois: [candidate], currentKmMarkMeters: 0, etaDayOfWeek: mondayTenAM.dayOfWeek,
            etaMinuteOfDay: mondayTenAM.minuteOfDay)

        XCTAssertEqual(result.map(\.osmId), [1])
    }

    func testStopWithNoNormalizedHoursAtAllIsNotExcluded() {
        // A route cached before this field existed (nil, not unknown — RULE-32's backward
        // compatibility case) must fail open exactly like an explicit `unknown`.
        let candidate = poi(osmId: 1, kmMarkMeters: 1_000, normalizedOpeningHours: nil)

        let result = POILookahead.candidates(
            pois: [candidate], currentKmMarkMeters: 0, etaDayOfWeek: mondayTenAM.dayOfWeek,
            etaMinuteOfDay: mondayTenAM.minuteOfDay)

        XCTAssertEqual(result.map(\.osmId), [1])
    }

    func testAClosedStopDoesNotOccupyACapSlot() {
        // 6 candidates: 1 confirmed closed, 5 open — the cap must return exactly the 5 open
        // ones, not 4 open + the closed one, proving exclusion runs before the cap applies.
        let closedHours = PersistedNormalizedOpeningHours(
            alwaysOpen: false, unknown: false,
            intervals: [PersistedWeeklyOpenInterval(dayOfWeek: 1, startMinuteOfDay: 720, endMinuteOfDay: 1080)])
        let closed = poi(osmId: 99, kmMarkMeters: 1_000, normalizedOpeningHours: closedHours)
        let openPois = (1...5).map {
            poi(
                osmId: Int64($0), kmMarkMeters: 1_000,
                normalizedOpeningHours: PersistedNormalizedOpeningHours(alwaysOpen: true, unknown: false, intervals: []))
        }

        let result = POILookahead.candidates(
            pois: openPois + [closed], currentKmMarkMeters: 0, etaDayOfWeek: mondayTenAM.dayOfWeek,
            etaMinuteOfDay: mondayTenAM.minuteOfDay)

        XCTAssertEqual(Set(result.map(\.osmId)), Set(1...5))
    }
}

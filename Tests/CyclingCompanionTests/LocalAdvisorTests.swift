import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.2 validation (RULE-19/RULE-20/RULE-21 in spec/rules.md, AC-25/AC-26).
final class LocalAdvisorTests: XCTestCase {

    private func candidate(osmId: Int64 = 1, name: String = "Café Sample", detourMeters: Double = 300) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: name, latitude: 52.0, longitude: 13.0,
            kmMarkMeters: 1_000, detourMeters: detourMeters, openingHours: nil)
    }

    private func emptySnapshot() -> FeatureSnapshot {
        FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Fresh rider (scenario 2): no suggestion

    func testFreshRiderSnapshotYieldsNoSuggestion() {
        let decision = LocalAdvisor.decide(
            snapshot: emptySnapshot(), candidates: [candidate()], hasQualifyingStopAhead: false,
            secondsSinceLastCheckThatProceeded: 0)

        XCTAssertFalse(decision.suggest)
        XCTAssertNil(decision.stopId)
        XCTAssertNil(decision.urgency)
        XCTAssertNil(decision.reason)
        XCTAssertNil(decision.message)
    }

    // MARK: - Priority order when multiple conditions are true (AC-26)

    func testHRDriftAndCadenceDropBothCrossedYieldsHRDriftNotCadenceDrop() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.5, cadenceDrop: -30)

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: [candidate()], hasQualifyingStopAhead: false,
            secondsSinceLastCheckThatProceeded: 0)

        XCTAssertEqual(decision.reason, FatigueFeature.hrDrift.rawValue)
    }

    // MARK: - Always a complete decision (AC-25)

    func testApprovedSuggestionHasAllFiveFieldsPopulated() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.5)

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: [candidate(osmId: 42, name: "Bakery")], hasQualifyingStopAhead: false,
            secondsSinceLastCheckThatProceeded: 0)

        XCTAssertTrue(decision.suggest)
        XCTAssertEqual(decision.stopId, "42")
        XCTAssertNotNil(decision.urgency)
        XCTAssertEqual(decision.reason, FatigueFeature.hrDrift.rawValue)
        XCTAssertNotNil(decision.message)
        XCTAssertTrue(decision.message?.contains("Bakery") ?? false)
    }

    func testZeroCandidatesYieldsNoSuggestionEvenWithAFatigueSignal() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.5)

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: [], hasQualifyingStopAhead: false, secondsSinceLastCheckThatProceeded: 0)

        XCTAssertFalse(decision.suggest)
        XCTAssertNil(decision.stopId)
        XCTAssertNil(decision.urgency)
        XCTAssertNil(decision.reason)
        XCTAssertNil(decision.message)
    }

    func testQualifyingStopAheadWithNoFatigueSignalStillSuggestsWithAGenericMessage() {
        let decision = LocalAdvisor.decide(
            snapshot: emptySnapshot(), candidates: [candidate()], hasQualifyingStopAhead: true,
            secondsSinceLastCheckThatProceeded: 0)

        XCTAssertTrue(decision.suggest)
        XCTAssertNil(decision.reason, "no feature crossed its threshold — the trigger fired on the stop-ahead branch alone")
        XCTAssertNotNil(decision.message)
    }

    func testBestRankedCandidateIsSuggested() {
        // POILookahead already ranks candidates; LocalAdvisor must pick the first (best) one.
        let best = candidate(osmId: 1, name: "Closer", detourMeters: 100)
        let worse = candidate(osmId: 2, name: "Farther", detourMeters: 900)
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.5)

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: [best, worse], hasQualifyingStopAhead: false,
            secondsSinceLastCheckThatProceeded: 0)

        XCTAssertEqual(decision.stopId, "1")
    }
}

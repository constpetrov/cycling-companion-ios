import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.3/task-3.4 validation (RULE-22/RULE-23 in spec/rules.md, AC-27 through AC-36).
final class GuardrailGateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let log = DecisionLog()

    private func candidate(osmId: Int64 = 1, detourMeters: Double = 300) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: "Café Sample", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: 1_000, detourMeters: detourMeters, openingHours: nil)
    }

    private func approved(stopId: String = "1") -> AdvisorDecision {
        AdvisorDecision(suggest: true, stopId: stopId, urgency: "normal", reason: nil, message: "a stop is coming up")
    }

    private var noSuggestion: AdvisorDecision {
        AdvisorDecision(suggest: false, stopId: nil, urgency: nil, reason: nil, message: nil)
    }

    private func evaluate(
        decision: AdvisorDecision, candidates: [PersistedPoiInput], lastApprovedSuggestionTimestamp: Date? = nil,
        lastStopTimestamp: Date? = nil
    ) -> AdvisorDecision {
        GuardrailGate.evaluate(
            decision: decision, candidates: candidates, now: now,
            lastApprovedSuggestionTimestamp: lastApprovedSuggestionTimestamp, lastStopTimestamp: lastStopTimestamp,
            log: log)
    }

    // MARK: - Non-suggesting decision passes through unchanged

    func testNonSuggestingDecisionPassesThroughUnchanged() {
        let result = evaluate(decision: noSuggestion, candidates: [candidate()])

        XCTAssertFalse(result.suggest)
    }

    // MARK: - Candidate list membership (AC-27)

    func testStopNotInCandidateListIsRejected() {
        let result = evaluate(decision: approved(stopId: "999"), candidates: [candidate(osmId: 1)])

        XCTAssertFalse(result.suggest)
        XCTAssertNil(result.stopId)
    }

    func testStopInCandidateListIsNotRejectedByMembershipCheck() {
        let result = evaluate(decision: approved(stopId: "1"), candidates: [candidate(osmId: 1, detourMeters: 300)])

        XCTAssertTrue(result.suggest)
    }

    // MARK: - Detour cap, three-point boundary (AC-28/AC-29/AC-30, scenario 5)

    func testDetourWithinCapIsApproved() {
        let result = evaluate(decision: approved(stopId: "1"), candidates: [candidate(osmId: 1, detourMeters: 1_999)])

        XCTAssertTrue(result.suggest)
        XCTAssertEqual(result.stopId, "1")
    }

    func testDetourAtExactlyCapIsApproved() {
        let result = evaluate(
            decision: approved(stopId: "1"),
            candidates: [candidate(osmId: 1, detourMeters: GuardrailGate.detourCapMeters)])

        XCTAssertTrue(result.suggest)
    }

    func testDetourBeyondCapIsRejected() {
        let result = evaluate(decision: approved(stopId: "1"), candidates: [candidate(osmId: 1, detourMeters: 2_001)])

        XCTAssertFalse(result.suggest)
        XCTAssertNil(result.stopId)
    }

    // MARK: - Rate limit since last approved suggestion, three-point boundary (AC-31/AC-32/AC-33, scenario 6)

    func testFewerThanRateLimitMinutesSinceLastApprovedSuggestionIsRejected() {
        let lastApproved = now.addingTimeInterval(-(GuardrailGate.rateLimitMinutes * 60 - 1))

        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)],
            lastApprovedSuggestionTimestamp: lastApproved)

        XCTAssertFalse(result.suggest)
    }

    func testExactlyRateLimitMinutesSinceLastApprovedSuggestionIsApproved() {
        let lastApproved = now.addingTimeInterval(-(GuardrailGate.rateLimitMinutes * 60))

        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)],
            lastApprovedSuggestionTimestamp: lastApproved)

        XCTAssertTrue(result.suggest)
    }

    func testBeyondRateLimitMinutesSinceLastApprovedSuggestionIsApproved() {
        let lastApproved = now.addingTimeInterval(-(GuardrailGate.rateLimitMinutes * 60 + 1))

        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)],
            lastApprovedSuggestionTimestamp: lastApproved)

        XCTAssertTrue(result.suggest)
    }

    func testNoPriorApprovedSuggestionIsNotRateLimited() {
        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)],
            lastApprovedSuggestionTimestamp: nil)

        XCTAssertTrue(result.suggest)
    }

    // MARK: - Post-stop quiet period, three-point boundary (AC-34/AC-35/AC-36, scenario 7)

    func testFewerThanPostStopQuietMinutesSinceLastStopIsRejected() {
        let lastStop = now.addingTimeInterval(-(GuardrailGate.postStopQuietMinutes * 60 - 1))

        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)], lastStopTimestamp: lastStop)

        XCTAssertFalse(result.suggest)
    }

    func testExactlyPostStopQuietMinutesSinceLastStopIsApproved() {
        let lastStop = now.addingTimeInterval(-(GuardrailGate.postStopQuietMinutes * 60))

        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)], lastStopTimestamp: lastStop)

        XCTAssertTrue(result.suggest)
    }

    func testBeyondPostStopQuietMinutesSinceLastStopIsApproved() {
        let lastStop = now.addingTimeInterval(-(GuardrailGate.postStopQuietMinutes * 60 + 1))

        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)], lastStopTimestamp: lastStop)

        XCTAssertTrue(result.suggest)
    }

    func testNoPriorStopIsNotQuietPeriodLimited() {
        let result = evaluate(
            decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)], lastStopTimestamp: nil)

        XCTAssertTrue(result.suggest)
    }

    // MARK: - Every verdict is recorded (AC-44)

    func testEveryVerdictIsRecordedInTheDecisionLog() {
        _ = evaluate(decision: approved(stopId: "1"), candidates: [candidate(osmId: 1)])
        _ = evaluate(decision: approved(stopId: "999"), candidates: [candidate(osmId: 1)])

        XCTAssertEqual(log.guardrailVerdicts.count, 2)
    }
}

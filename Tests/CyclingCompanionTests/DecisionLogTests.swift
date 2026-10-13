import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.3 validation (RULE-25 in spec/rules.md, AC-41/AC-43/AC-44/AC-45): a denied-permission
/// run still records the Local Advisor decision and Guardrail Gate verdict, but posts nothing.
final class DecisionLogTests: XCTestCase {

    private func candidate(osmId: Int64 = 1) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: "Café Sample", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: 1_000, detourMeters: 300, openingHours: nil)
    }

    func testDeniedPermissionStillRecordsTheAdvisorDecisionAndGuardrailVerdictButPostsNothing() async throws {
        let log = DecisionLog()
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.5)

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: [candidate()], hasQualifyingStopAhead: false,
            secondsSinceLastCheckThatProceeded: 0, log: log)
        let verdict = GuardrailGate.evaluate(
            decision: decision, candidates: [candidate()], now: Date(timeIntervalSince1970: 0),
            lastApprovedSuggestionTimestamp: nil, lastStopTimestamp: nil, log: log)

        let scheduling = FakeNotificationScheduling(grantOnRequest: false)
        let notifier = Notifier(scheduling: scheduling, log: log)
        try await notifier.notify(verdict: verdict, candidates: [candidate()])

        XCTAssertEqual(log.advisorDecisions.count, 1)
        XCTAssertTrue(log.advisorDecisions.first?.suggest ?? false)
        XCTAssertEqual(log.guardrailVerdicts.count, 1)
        XCTAssertTrue(log.guardrailVerdicts.first?.suggest ?? false)
        XCTAssertTrue(log.postedNotifications.isEmpty)
    }

    func testLocalAdvisorAndGuardrailGateFireWithNoConnectivityDependencyAtAll() async throws {
        // E2E scenario 8 (design.md), connectivity-independence half only — upload-after-
        // reconnect is out of scope per spec.md. Nothing in this call chain touches
        // `HTTPTransport`/`URLSession`/any network type, so there is no "connectivity" to lose
        // in the first place; this proves the chain still fires by construction.
        let log = DecisionLog()
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0), hrDrift: 0.5)

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: [candidate()], hasQualifyingStopAhead: false,
            secondsSinceLastCheckThatProceeded: 0, log: log)
        let verdict = GuardrailGate.evaluate(
            decision: decision, candidates: [candidate()], now: Date(timeIntervalSince1970: 0),
            lastApprovedSuggestionTimestamp: nil, lastStopTimestamp: nil, log: log)

        XCTAssertTrue(decision.suggest)
        XCTAssertTrue(verdict.suggest)
    }
}

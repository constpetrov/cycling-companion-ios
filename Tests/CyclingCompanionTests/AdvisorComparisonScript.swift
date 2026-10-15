import Foundation
import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// A representative subset of design.md's E2E scenarios (2, 3, 7, 11) — enough variety in
/// feature-snapshot shape and candidate presence to compare LocalAdvisor's rule-based
/// decisions against the Nebius-backed remote Advisor's, without trying to be an exhaustive
/// restatement of every scenario (spec.md's explicit scope: a one-off comparison, not the full
/// nightly eval harness).
enum AdvisorComparisonReport {
    struct Scenario {
        let name: String
        let snapshot: FeatureSnapshot
        let candidates: [PersistedPoiInput]
    }

    /// task-5.2 (RULE-23 in spec/rules.md, AC-24): one remote call per (scenario, condition)
    /// pair — `riderIdentity` is the sign-in `placeholderIdentity`, surfaced in the report so a
    /// seeded and a fresh run are visibly distinguishable even when their decisions happen to
    /// match.
    struct HistoryCondition {
        let label: String
        let riderIdentity: String
        let advisorClient: AdvisorClient
    }

    private static func candidate(osmId: Int64 = 1) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: "Comparison Cafe", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: 12_000, detourMeters: 400, openingHours: nil, normalizedOpeningHours: nil)
    }

    static let scenarios: [Scenario] = [
        Scenario(
            name: "fresh-rider-no-candidates",
            snapshot: FeatureSnapshot(
                timestamp: Date(timeIntervalSince1970: 0), speedVsBaseline: nil, workDone: nil,
                rideSoFarVsLongest: nil, conditions: nil, speedTrend: 0.0, hrDrift: 0.02, cadenceDrop: 0,
                timeSinceLastStopSeconds: 600, remainingEffortMeters: 20_000),
            candidates: []),
        Scenario(
            name: "fading-rider-cafe-ahead",
            snapshot: FeatureSnapshot(
                timestamp: Date(timeIntervalSince1970: 0), speedVsBaseline: nil, workDone: nil,
                rideSoFarVsLongest: nil, conditions: nil, speedTrend: -0.05, hrDrift: 0.15, cadenceDrop: nil,
                timeSinceLastStopSeconds: 3_600, remainingEffortMeters: 15_000),
            candidates: [candidate()]),
        Scenario(
            name: "healthy-rider-stop-ahead",
            snapshot: FeatureSnapshot(
                timestamp: Date(timeIntervalSince1970: 0), speedVsBaseline: nil, workDone: nil,
                rideSoFarVsLongest: nil, conditions: nil, speedTrend: 0.0, hrDrift: 0.01, cadenceDrop: 0,
                timeSinceLastStopSeconds: 300, remainingEffortMeters: 25_000),
            candidates: [candidate()]),
        Scenario(
            name: "sensor-dropout-cadence-only",
            snapshot: FeatureSnapshot(
                timestamp: Date(timeIntervalSince1970: 0), speedVsBaseline: nil, workDone: nil,
                rideSoFarVsLongest: nil, conditions: nil, speedTrend: nil, hrDrift: nil, cadenceDrop: -15,
                timeSinceLastStopSeconds: 2_400, remainingEffortMeters: 10_000),
            candidates: [candidate()]),
    ]

    /// Replays every scenario through both advisors, once per `historyConditions` entry, and
    /// reports them side by side — one CSV row per (scenario, condition) pair (AC-24: "run it
    /// once against an empty seeded history and once against a seeded history, and ... report
    /// both results"). `historyConditions` is injected so this is testable against a stubbed
    /// transport (no live backend/NEBIUS_API_KEY needed to validate the report's mechanics) as
    /// well as runnable against a real one.
    static func generate(scenarios: [Scenario], historyConditions: [HistoryCondition]) async -> String {
        var lines = [
            "scenario,history,rider_identity,local_suggest,local_stop_id,local_reason,remote_suggest,remote_stop_id,remote_reason"
        ]
        for scenario in scenarios {
            let local = LocalAdvisor.decide(
                snapshot: scenario.snapshot, candidates: scenario.candidates,
                hasQualifyingStopAhead: !scenario.candidates.isEmpty, secondsSinceLastCheckThatProceeded: 0,
                log: DecisionLog())
            for condition in historyConditions {
                let remote = await condition.advisorClient.requestDecision(
                    rideId: "comparison", routeId: "comparison", snapshot: scenario.snapshot,
                    candidates: scenario.candidates)
                lines.append(
                    [
                        scenario.name, condition.label, condition.riderIdentity, "\(local.suggest)",
                        local.stopId ?? "-", local.reason ?? "-", remote.map { "\($0.suggest)" } ?? "nil",
                        remote?.stopId ?? "-", remote?.reason ?? "-",
                    ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// task-4.1/task-5.2 validation (RULE-17/RULE-23 in spec/rules.md, AC-16/AC-24). The actual
/// live-comparison test is skipped by default — `xcodebuild test` with no extra environment
/// never attempts a real network call — since it needs a running backend and (per
/// spec/rules.md's External Dependencies) a real `NEBIUS_API_KEY` to be genuinely informative,
/// neither of which this environment has. The mechanics are still validated below, against a
/// stubbed transport.
///
/// Before running the live test with `RUN_ADVISOR_COMPARISON=1`, seed `Self.seededHistoryRiderIdentity`'s
/// history once against that same backend — the backend's sign-in endpoint reuses the same
/// `Rider` row for a given `placeholderIdentity` every time (see `AuthController.signIn`), so
/// seeding it once is enough for repeat runs. This script cannot invoke backend repository
/// seeding itself (no JDBC/JPA access from Swift): sign in as `Self.seededHistoryRiderIdentity`
/// once to learn its backend-assigned rider id, then run the backend's
/// `RiderHistorySeeder.seedMatchingHistory(riderId, routeId)` (task-5.1) against that id and a
/// real route id before running this script.
final class AdvisorComparisonScript: XCTestCase {
    static let seededHistoryRiderIdentity = "advisor-comparison-seeded-rider"

    private actor StubbedComparisonTransport: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url!.path
            let body: Data
            if path.hasSuffix("sign-in") {
                body = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#.data(using: .utf8)!
            } else {
                body = #"{"suggest":true,"stopId":"1","urgency":"normal","reason":"remote-reason","message":"msg"}"#
                    .data(using: .utf8)!
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    @MainActor
    private func advisorClient(baseURL: URL, placeholderIdentity: String, transport: HTTPTransport) -> AdvisorClient {
        let authClient = AuthStubClient(baseURL: baseURL, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient, placeholderIdentity: placeholderIdentity)
        return AdvisorClient(baseURL: baseURL, authClient: authClient, lazySignIn: lazySignIn, transport: transport)
    }

    @MainActor
    private func stubbedHistoryConditions() -> [AdvisorComparisonReport.HistoryCondition] {
        let baseURL = URL(string: "https://backend.example.com")!
        let transport = StubbedComparisonTransport()
        return [
            AdvisorComparisonReport.HistoryCondition(
                label: "empty-history", riderIdentity: "fresh-rider-\(UUID().uuidString)",
                advisorClient: advisorClient(
                    baseURL: baseURL, placeholderIdentity: "fresh-rider-\(UUID().uuidString)", transport: transport)),
            AdvisorComparisonReport.HistoryCondition(
                label: "seeded-history", riderIdentity: Self.seededHistoryRiderIdentity,
                advisorClient: advisorClient(
                    baseURL: baseURL, placeholderIdentity: Self.seededHistoryRiderIdentity, transport: transport)),
        ]
    }

    @MainActor
    func testReportHasTwoRowsPerScenarioWithDistinctRiderIdentifiers() async throws {
        let historyConditions = stubbedHistoryConditions()
        let report = await AdvisorComparisonReport.generate(
            scenarios: AdvisorComparisonReport.scenarios, historyConditions: historyConditions)

        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(
            lines.count, AdvisorComparisonReport.scenarios.count * 2 + 1,
            "header + two rows (empty-history, seeded-history) per scenario")

        for (scenarioIndex, scenario) in AdvisorComparisonReport.scenarios.enumerated() {
            let emptyHistoryRow = lines[scenarioIndex * 2 + 1]
            let seededHistoryRow = lines[scenarioIndex * 2 + 2]
            XCTAssertTrue(emptyHistoryRow.hasPrefix("\(scenario.name),empty-history,"))
            XCTAssertTrue(seededHistoryRow.hasPrefix("\(scenario.name),seeded-history,"))
            XCTAssertFalse(
                emptyHistoryRow.contains("nil"), "every row must have a populated remote column, not a fallback nil")
            XCTAssertFalse(seededHistoryRow.contains("nil"))

            let emptyHistoryIdentity = historyConditions[0].riderIdentity
            let seededHistoryIdentity = historyConditions[1].riderIdentity
            XCTAssertNotEqual(emptyHistoryIdentity, seededHistoryIdentity, "rider identifiers must be distinct")
            XCTAssertTrue(emptyHistoryRow.contains(emptyHistoryIdentity))
            XCTAssertTrue(seededHistoryRow.contains(seededHistoryIdentity))
        }
    }

    @MainActor
    func testRunComparisonAgainstALiveBackend() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_ADVISOR_COMPARISON"] != nil,
            """
            Set RUN_ADVISOR_COMPARISON=1 and ADVISOR_COMPARISON_BASE_URL (defaults to \
            http://localhost:8080) to actually run this against a live backend. Deferred per \
            spec/spec.md's External Dependencies: NEBIUS_API_KEY isn't available in this \
            environment. Seed Self.seededHistoryRiderIdentity's rider history first — see this \
            class's doc comment.
            """)

        let baseURL = URL(
            string: ProcessInfo.processInfo.environment["ADVISOR_COMPARISON_BASE_URL"] ?? "http://localhost:8080")!
        let historyConditions = [
            AdvisorComparisonReport.HistoryCondition(
                label: "empty-history", riderIdentity: "fresh-rider-\(UUID().uuidString)",
                advisorClient: advisorClient(
                    baseURL: baseURL, placeholderIdentity: "fresh-rider-\(UUID().uuidString)",
                    transport: URLSession.shared)),
            AdvisorComparisonReport.HistoryCondition(
                label: "seeded-history", riderIdentity: Self.seededHistoryRiderIdentity,
                advisorClient: advisorClient(
                    baseURL: baseURL, placeholderIdentity: Self.seededHistoryRiderIdentity,
                    transport: URLSession.shared)),
        ]

        let report = await AdvisorComparisonReport.generate(
            scenarios: AdvisorComparisonReport.scenarios, historyConditions: historyConditions)
        print(report)
        XCTAssertFalse(report.isEmpty)
    }
}

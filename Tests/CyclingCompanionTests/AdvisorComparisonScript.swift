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

    /// Replays every scenario through both advisors and reports them side by side, one CSV row
    /// per scenario. `advisorClient` is injected so this is testable against a stubbed
    /// transport (no live backend/NEBIUS_API_KEY needed to validate the report's mechanics) as
    /// well as runnable against a real one.
    static func generate(scenarios: [Scenario], advisorClient: AdvisorClient) async -> String {
        var lines = ["scenario,local_suggest,local_stop_id,local_reason,remote_suggest,remote_stop_id,remote_reason"]
        for scenario in scenarios {
            let local = LocalAdvisor.decide(
                snapshot: scenario.snapshot, candidates: scenario.candidates,
                hasQualifyingStopAhead: !scenario.candidates.isEmpty, secondsSinceLastCheckThatProceeded: 0,
                log: DecisionLog())
            let remote = await advisorClient.requestDecision(
                rideId: "comparison", routeId: "comparison", snapshot: scenario.snapshot,
                candidates: scenario.candidates)
            lines.append(
                [
                    scenario.name, "\(local.suggest)", local.stopId ?? "-", local.reason ?? "-",
                    remote.map { "\($0.suggest)" } ?? "nil", remote?.stopId ?? "-", remote?.reason ?? "-",
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

/// task-4.1 validation (RULE-17 in spec/rules.md, AC-16). The actual live-comparison test is
/// skipped by default — `xcodebuild test` with no extra environment never attempts a real
/// network call — since it needs a running backend and (per spec/rules.md's External
/// Dependencies) a real `NEBIUS_API_KEY` to be genuinely informative, neither of which this
/// environment has. The mechanics are still validated below, against a stubbed transport.
final class AdvisorComparisonScript: XCTestCase {

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
    private func stubbedAdvisorClient() -> AdvisorClient {
        let transport = StubbedComparisonTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        return AdvisorClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, lazySignIn: lazySignIn,
            transport: transport)
    }

    @MainActor
    func testReportHasOneRowPerScenarioWithBothColumnsPopulated() async throws {
        let report = await AdvisorComparisonReport.generate(
            scenarios: AdvisorComparisonReport.scenarios, advisorClient: stubbedAdvisorClient())

        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, AdvisorComparisonReport.scenarios.count + 1, "header + one row per scenario")
        for (index, scenario) in AdvisorComparisonReport.scenarios.enumerated() {
            let row = lines[index + 1]
            XCTAssertTrue(row.hasPrefix(scenario.name))
            XCTAssertFalse(row.contains("nil"), "every row must have a populated remote column, not a fallback nil")
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
            environment.
            """)

        let baseURL = URL(
            string: ProcessInfo.processInfo.environment["ADVISOR_COMPARISON_BASE_URL"] ?? "http://localhost:8080")!
        let authClient = AuthStubClient(baseURL: baseURL)
        let lazySignIn = LazySignIn(authClient: authClient)
        let advisorClient = AdvisorClient(baseURL: baseURL, authClient: authClient, lazySignIn: lazySignIn)

        let report = await AdvisorComparisonReport.generate(
            scenarios: AdvisorComparisonReport.scenarios, advisorClient: advisorClient)
        print(report)
        XCTAssertFalse(report.isEmpty)
    }
}

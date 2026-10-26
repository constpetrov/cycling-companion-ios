import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.7 (RULE-18): AC-67, AC-68, AC-70, and AC-78's suggestion counts.
final class SuggestionUploadTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func payload(responses: [SuggestionResponsePayload]?) -> RideIngestRequestPayload {
        RideIngestRequestPayload(
            routeId: "route-1", startTime: t0, endTime: t0 + 3_600, totalDistanceMeters: 20_000,
            totalMovingTimeSeconds: 3_000, stopsTaken: 1, outcome: "TYPICAL", featureSnapshots: [],
            suggestionResponses: responses)
    }

    private func encoded(_ payload: RideIngestRequestPayload) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(payload)) as! [String: Any]
    }

    /// AC-67/AC-68: stop id, times and the uppercase answer — and no coordinates.
    func testResponsesAreUploadedWithStopIdTimesAndAnswerOnly() throws {
        let response = SuggestionResponsePayload(
            SuggestionResponse(suggestionId: "a", stopId: 1001, suggestedAt: t0, answer: .accepted, respondedAt: t0 + 30))

        let json = try encoded(payload(responses: [response]))

        let first = try XCTUnwrap((json["suggestionResponses"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["stopId"] as? Int, 1001)
        XCTAssertEqual(first["response"] as? String, "ACCEPTED")
        XCTAssertNotNil(first["suggestedAt"])
        XCTAssertNotNil(first["respondedAt"])
        XCTAssertEqual(Set(first.keys), ["stopId", "suggestedAt", "response", "respondedAt"])
    }

    /// Milestone 9 AC-111: a remote suggestion's answer is uploaded with its trace id.
    func testAResponseIsUploadedWithItsTraceId() throws {
        let response = SuggestionResponsePayload(
            SuggestionResponse(
                suggestionId: "a", stopId: 1001, suggestedAt: t0, answer: .declined, respondedAt: t0 + 30,
                traceId: "0f8a3c1e-2b4d-4e6f-8a9b-1c2d3e4f5a6b"))

        let json = try encoded(payload(responses: [response]))

        let first = try XCTUnwrap((json["suggestionResponses"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["traceId"] as? String, "0f8a3c1e-2b4d-4e6f-8a9b-1c2d3e4f5a6b")
    }

    /// Milestone 9 AC-112: without a trace id the key is left out and the response still goes.
    func testAResponseWithoutATraceIdOmitsTheKey() throws {
        let response = SuggestionResponsePayload(
            SuggestionResponse(suggestionId: "a", stopId: 1001, suggestedAt: t0, answer: .none, respondedAt: nil))

        let json = try encoded(payload(responses: [response]))

        let first = try XCTUnwrap((json["suggestionResponses"] as? [[String: Any]])?.first)
        XCTAssertNil(first["traceId"])
        XCTAssertEqual(first["stopId"] as? Int, 1001)
    }

    func testANoAnswerResponseHasNoResponseTime() throws {
        let response = SuggestionResponsePayload(
            SuggestionResponse(suggestionId: "a", stopId: 1001, suggestedAt: t0, answer: .none, respondedAt: nil))

        let json = try encoded(payload(responses: [response]))

        let first = try XCTUnwrap((json["suggestionResponses"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["response"] as? String, "NONE")
        XCTAssertNil(first["respondedAt"])
    }

    func testTheFieldIsOmittedWhenThereAreNoResponses() throws {
        XCTAssertNil(try encoded(payload(responses: nil))["suggestionResponses"])
    }

    /// AC-70: an upload queued by an older build (no such field) still decodes.
    func testAQueuedPayloadFromAnOlderBuildStillDecodes() throws {
        let legacy = #"""
            {"routeId":"route-1","startTime":"2026-10-20T08:00:00Z","endTime":"2026-10-20T10:00:00Z",
             "totalDistanceMeters":40000,"totalMovingTimeSeconds":6000,"stopsTaken":1,"outcome":"TYPICAL",
             "featureSnapshots":[]}
            """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(RideIngestRequestPayload.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.suggestionResponses)
        XCTAssertEqual(decoded.routeId, "route-1")
    }

    // MARK: - Summary counts (AC-78)

    @MainActor
    private func summary(with state: PersistedSuggestionState?) -> RideSummaryViewModel {
        let ride = PersistedRide(
            id: "ride-1", routeId: "route-1", startTime: t0, endTime: t0 + 3_600, totalDistanceMeters: 20_000,
            totalMovingTimeSeconds: 3_000, track: [], suggestionState: state)
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!)
        let uploader = RideUploader(
            ingestClient: RideIngestClient(
                baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
                lazySignIn: LazySignIn(authClient: authClient)),
            queue: PendingRideUploadQueue(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        return RideSummaryViewModel(outcome: .saved(ride), uploader: uploader, decisionLog: DecisionLog())
    }

    @MainActor
    func testTheSummaryCountsSuggestionsByAnswer() {
        var ledger = SuggestionLedger()
        func suggestion(_ id: String, _ stop: Int64) -> ApprovedSuggestion {
            ApprovedSuggestion(
                id: id, stopId: stop, name: nil, type: "CAFE", latitude: 52, longitude: 13, kmMarkMeters: 1_000,
                detourMeters: 100, message: nil, suggestedAt: t0)
        }
        ledger.approve(suggestion("a", 1))
        ledger.respond(.accepted, to: "a", at: t0 + 5)
        ledger.approve(suggestion("b", 2))
        ledger.respond(.declined, to: "b", at: t0 + 6)
        ledger.approve(suggestion("c", 3))  // left unanswered

        XCTAssertEqual(summary(with: ledger.persisted).suggestionsText, "1 accepted · 1 declined · 1 no answer")
    }

    @MainActor
    func testTheSummarySaysWhenThereWereNoSuggestions() {
        XCTAssertEqual(summary(with: nil).suggestionsText, "No stop suggestions")
    }
}

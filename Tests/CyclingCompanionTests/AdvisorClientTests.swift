import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Routes requests by path suffix, tracking call order so tests can confirm sign-in happens
/// before the Advisor call (RULE-19 in spec/rules.md) — matches
/// `CorridorImportCoordinatorTests`' established convention for this.
private actor PathRoutedResponder: HTTPTransport {
    private var responsesByPathSuffix: [String: (Int, Data)]
    private(set) var pathsCalledInOrder: [String] = []
    private(set) var lastRequestBody: Data?

    init(responsesByPathSuffix: [String: (Int, Data)]) {
        self.responsesByPathSuffix = responsesByPathSuffix
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        pathsCalledInOrder.append(path)
        if path.hasSuffix("advisor/decision") {
            lastRequestBody = request.httpBody
        }
        guard let key = responsesByPathSuffix.keys.first(where: { path.hasSuffix($0) }) else {
            XCTFail("No stub registered for path \(path)")
            throw AdvisorClientError.unexpectedResponse
        }
        let (statusCode, body) = responsesByPathSuffix[key]!
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private struct ThrowingTransport: HTTPTransport {
    struct TransportError: Error {}
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw TransportError()
    }
}

/// task-1.4 validation (RULE-2/RULE-13/RULE-14/RULE-19 in spec/rules.md, AC-3/AC-4/AC-5/AC-18).
final class AdvisorClientTests: XCTestCase {

    private let signInResponse = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
        .data(using: .utf8)!

    private func snapshot() -> FeatureSnapshot {
        FeatureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_000), speedVsBaseline: nil, workDone: nil,
            rideSoFarVsLongest: nil, conditions: nil, speedTrend: 1.5, hrDrift: nil, cadenceDrop: nil,
            timeSinceLastStopSeconds: 120, remainingEffortMeters: 5_000)
    }

    private func candidates() -> [PersistedPoiInput] {
        [
            PersistedPoiInput(
                osmId: 42, type: "CAFE_BAKERY_RESTAURANT", name: "Test Cafe", latitude: 52.0, longitude: 13.0,
                kmMarkMeters: 12_000, detourMeters: 400, openingHours: "Mo-Fr 08:00-18:00",
                normalizedOpeningHours: nil)
        ]
    }

    @MainActor
    private func makeClient(
        transport: HTTPTransport, clock: Clock = SystemClock(), deadlineSeconds: TimeInterval = 8.0
    ) -> AdvisorClient {
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        return AdvisorClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, lazySignIn: lazySignIn,
            transport: transport, clock: clock, deadlineSeconds: deadlineSeconds)
    }

    @MainActor
    func testASuccessfulSchemaValidResponseReturnsADecision() async {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "advisor/decision": (
                200,
                #"{"suggest":true,"stopId":"42","urgency":"normal","reason":"speedTrend","message":"Test Cafe is coming up."}"#
                    .data(using: .utf8)!),
        ])
        // A real SystemClock-backed deadline is a race against actual wall-clock time, which a
        // slow/contended CI runner can occasionally lose even though the stub has no real
        // latency — GatedClock's sleep never resolves unless released (never is, here), so the
        // deadline side can never win and this is deterministic regardless of machine speed.
        let client = makeClient(transport: responder, clock: GatedClock())

        let decision = await client.requestDecision(
            rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: candidates())

        XCTAssertEqual(decision?.suggest, true)
        XCTAssertEqual(decision?.stopId, "42")
    }

    @MainActor
    func testSignsInBeforeTheAdvisorCallWhenNotYetSignedIn() async {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "advisor/decision": (200, #"{"suggest":false}"#.data(using: .utf8)!),
        ])
        let client = makeClient(transport: responder, clock: GatedClock())

        _ = await client.requestDecision(rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: [])

        let paths = await responder.pathsCalledInOrder
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].hasSuffix("sign-in"))
        XCTAssertTrue(paths[1].hasSuffix("advisor/decision"))
    }

    @MainActor
    func testTheRequestBodyCarriesRideIdRouteIdSnapshotAndCandidates() async throws {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "advisor/decision": (200, #"{"suggest":false}"#.data(using: .utf8)!),
        ])
        let client = makeClient(transport: responder, clock: GatedClock())

        _ = await client.requestDecision(
            rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: candidates())

        let capturedBody = await responder.lastRequestBody
        let body = try XCTUnwrap(capturedBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AdvisorDecisionRequestPayload.self, from: body)
        XCTAssertEqual(decoded.rideId, "ride-1")
        XCTAssertEqual(decoded.routeId, "route-1")
        XCTAssertEqual(decoded.featureSnapshot.speedTrend, 1.5)
        XCTAssertEqual(decoded.candidates.first?.osmId, 42)
        XCTAssertEqual(decoded.candidates.first?.name, "Test Cafe")
    }

    @MainActor
    func testANon2xxResponseReturnsNil() async {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "advisor/decision": (502, Data()),
        ])
        let client = makeClient(transport: responder)

        let decision = await client.requestDecision(
            rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: candidates())

        XCTAssertNil(decision)
    }

    @MainActor
    func testUnparseableJSONReturnsNil() async {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "advisor/decision": (200, "not json".data(using: .utf8)!),
        ])
        let client = makeClient(transport: responder)

        let decision = await client.requestDecision(
            rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: candidates())

        XCTAssertNil(decision)
    }

    @MainActor
    func testANetworkErrorReturnsNil() async {
        let client = makeClient(transport: ThrowingTransport())

        let decision = await client.requestDecision(
            rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: candidates())

        XCTAssertNil(decision)
    }

    @MainActor
    func testADeadlineThatFiresBeforeTheResponseArrivesReturnsNilAndDiscardsTheLateResponse() async {
        let clock = GatedClock()
        let transport = GatedTransport()
        let client = makeClient(transport: transport, clock: clock, deadlineSeconds: 8.0)

        let resultTask = Task {
            await client.requestDecision(rideId: "ride-1", routeId: "route-1", snapshot: snapshot(), candidates: [])
        }
        await clock.release()
        let decision = await resultTask.value

        XCTAssertNil(decision, "the 8-second deadline must win and the client must return nil, not hang or throw")

        // A late-arriving response after the deadline has already won must not be observable —
        // there is no result left to update.
        let body = #"{"suggest":false}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://backend.example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        await transport.release(data: body, response: response)
    }
}

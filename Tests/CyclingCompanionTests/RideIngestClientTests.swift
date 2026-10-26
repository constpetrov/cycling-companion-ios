import RoutePersistence
import XCTest

@testable import CyclingCompanion

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
        if path.hasSuffix("rides") {
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

/// task-2.4 validation (RULE-5/RULE-7 in spec/rules.md, AC-4/AC-5/AC-6).
final class RideIngestClientTests: XCTestCase {

    private let signInResponse = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
        .data(using: .utf8)!

    private func payload() -> RideIngestRequestPayload {
        let snapshot = FeatureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_000), speedVsBaseline: nil, workDone: nil,
            rideSoFarVsLongest: nil, conditions: nil, speedTrend: 1.5, hrDrift: nil, cadenceDrop: nil,
            timeSinceLastStopSeconds: 300, remainingEffortMeters: 5_000)
        return RideIngestRequestPayload(
            routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 3_600),
            totalDistanceMeters: 20_000, totalMovingTimeSeconds: 3_600, stopsTaken: 1, outcome: "TYPICAL",
            featureSnapshots: [FeatureSnapshotPayload(snapshot: snapshot)])
    }

    @MainActor
    private func makeClient(transport: HTTPTransport) -> RideIngestClient {
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        return RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, lazySignIn: lazySignIn,
            transport: transport)
    }

    @MainActor
    func testASuccessfulIngestReturnsTrue() async {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "rides": (200, #"{"rideId":"22222222-2222-2222-2222-222222222222"}"#.data(using: .utf8)!),
        ])
        let client = makeClient(transport: responder)

        let succeeded = await client.ingest(payload(), rideId: "ride-1")

        XCTAssertTrue(succeeded)
    }

    @MainActor
    func testANon2xxResponseReturnsFalse() async {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "rides": (500, Data()),
        ])
        let client = makeClient(transport: responder)

        let succeeded = await client.ingest(payload(), rideId: "ride-1")

        XCTAssertFalse(succeeded)
    }

    @MainActor
    func testANetworkErrorReturnsFalse() async {
        struct ThrowingTransport: HTTPTransport {
            struct TransportError: Error {}
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                throw TransportError()
            }
        }
        let client = makeClient(transport: ThrowingTransport())

        let succeeded = await client.ingest(payload(), rideId: "ride-1")

        XCTAssertFalse(succeeded)
    }

    @MainActor
    func testTheRequestBodyCarriesNoLatitudeOrLongitude() async throws {
        let responder = PathRoutedResponder(responsesByPathSuffix: [
            "sign-in": (200, signInResponse),
            "rides": (200, #"{"rideId":"22222222-2222-2222-2222-222222222222"}"#.data(using: .utf8)!),
        ])
        let client = makeClient(transport: responder)

        _ = await client.ingest(payload(), rideId: "ride-1")

        let capturedBody = await responder.lastRequestBody
        let body = try XCTUnwrap(capturedBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8)).lowercased()
        XCTAssertFalse(bodyString.contains("latitude"))
        XCTAssertFalse(bodyString.contains("longitude"))
    }
}

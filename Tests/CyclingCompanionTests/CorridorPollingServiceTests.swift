import RoutePersistence
import XCTest

@testable import CyclingCompanion

private actor SequencedStubTransport: HTTPTransport {
    private var responses: [(Int, Data)]
    private var callCount = 0

    init(responses: [(Int, Data)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = min(callCount, responses.count - 1)
        let (statusCode, body) = responses[index]
        callCount += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    var numberOfCalls: Int { callCount }
}

/// Throws the given error for every request, like a dropped connection.
private struct FailingTransport: HTTPTransport {
    let error: Error
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

/// Milestone 8 (RULE-18): one corridor status check, classified. AC-47 to AC-49, AC-29/AC-30.
final class CorridorPollingServiceTests: XCTestCase {

    private static func makeAuthClient() async throws -> AuthStubClient {
        let signInBody = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
            .data(using: .utf8)!
        struct SingleResponseTransport: HTTPTransport {
            let body: Data
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
        }
        let client = AuthStubClient(
            baseURL: URL(string: "https://backend.example.com")!,
            transport: SingleResponseTransport(body: signInBody))
        _ = try await client.signIn(placeholderIdentity: "device-test")
        return client
    }

    private static let readyBody = """
        {"status":"ready","pois":[{"osmId":-42,"type":"WATER","name":null,"latitude":52.0005,"longitude":13.0,"kmMarkMeters":55.6,"detourMeters":12.0,"openingHours":"unknown","normalizedOpeningHours":{"alwaysOpen":false,"unknown":true,"intervals":[]}}],"coverageRegion":"Netherlands","outsideMeters":1250.5}
        """.data(using: .utf8)!

    private func service(_ transport: HTTPTransport) async throws -> CorridorPollingService {
        CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: try await Self.makeAuthClient(),
            transport: transport)
    }

    private func result(status: Int, body: Data) async throws -> CorridorPollResult {
        try await service(SequencedStubTransport(responses: [(status, body)])).fetchStatus(routeId: "route-123")
    }

    func testAReadyAnswerIsAStatusWithStopsAndCoverage() async throws {
        guard case .status(let payload) = try await result(status: 200, body: Self.readyBody) else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(payload.status, "ready")
        XCTAssertEqual(payload.pois?.map(\.osmId), [-42], "a negative (outline) id decodes")
        XCTAssertEqual(payload.coverageRegion, "Netherlands")
        XCTAssertEqual(payload.outsideMeters, 1250.5)
    }

    /// AC-30: a milestone 7 backend's answer, without coverage, still decodes.
    func testAnAnswerWithoutCoverageDecodes() async throws {
        let body = #"{"status":"building","pois":null}"#.data(using: .utf8)!
        guard case .status(let payload) = try await result(status: 200, body: body) else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(payload.status, "building")
        XCTAssertNil(payload.coverageRegion)
        XCTAssertNil(payload.outsideMeters)
    }

    func testNotFoundIsNotFound() async throws {
        guard case .notFound = try await result(status: 404, body: Data()) else { return XCTFail("expected notFound") }
    }

    /// AC-48.
    func testServerErrorsAndThrottlingAreTransient() async throws {
        for status in [500, 502, 503, 408, 429, 401] {
            guard case .transient = try await result(status: status, body: Data()) else {
                return XCTFail("HTTP \(status) should be transient")
            }
        }
    }

    /// AC-47.
    func testNoConnectionAndTimeoutsAreTransient() async throws {
        for code in [URLError.notConnectedToInternet, .timedOut, .networkConnectionLost] {
            let service = try await service(FailingTransport(error: URLError(code)))
            guard case .transient = await service.fetchStatus(routeId: "route-123") else {
                return XCTFail("\(code) should be transient")
            }
        }
    }

    func testABodyThatDoesNotDecodeIsTransient() async throws {
        guard case .transient = try await result(status: 200, body: Data("{\"rideId\":\"x\"}".utf8)) else {
            return XCTFail("expected transient")
        }
    }
}

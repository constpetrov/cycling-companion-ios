import RoutePersistence
import SwiftData
import XCTest

@testable import CyclingCompanion

private actor FakeClock: Clock {
    private var _sleepCalls: [TimeInterval] = []

    var sleepCalls: [TimeInterval] {
        _sleepCalls
    }

    func sleep(for seconds: TimeInterval) async throws {
        _sleepCalls.append(seconds)
    }
}

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

/// AC-29/AC-37 in spec/criteria.md.
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

    @MainActor
    func testPollsAtFixedIntervalUntilReadyThenPersists() async throws {
        let authClient = try await Self.makeAuthClient()

        let buildingBody = #"{"status":"building","pois":null}"#.data(using: .utf8)!
        let readyBody = """
            {"status":"ready","pois":[{"osmId":42,"type":"WATER","name":null,"latitude":52.0005,"longitude":13.0,"kmMarkMeters":55.6,"detourMeters":12.0,"openingHours":"unknown"}]}
            """.data(using: .utf8)!

        let transport = SequencedStubTransport(responses: [
            (200, buildingBody), // first poll: still building
            (200, readyBody), // second poll: ready
        ])
        let clock = FakeClock()

        let service = CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            transport: transport, clock: clock, pollIntervalSeconds: 2.0)

        let finalStatus = try await service.pollUntilSettled(routeId: "route-123")

        XCTAssertEqual(finalStatus.status, "ready")
        XCTAssertEqual(finalStatus.pois?.count, 1)
        let sleepCalls = await clock.sleepCalls
        XCTAssertEqual(sleepCalls, [2.0])
        let calls = await transport.numberOfCalls
        XCTAssertEqual(calls, 2)

        // AC-29: persist Route + CorridorPOI into SwiftData once ready.
        let schema = Schema([RouteModel.self])
        let container = try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let points = [
            PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 100.0, cumulativeDistanceMeters: 0)
        ]
        let pois = (finalStatus.pois ?? []).map {
            PersistedPoiInput(
                osmId: $0.osmId, type: $0.type, name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                kmMarkMeters: $0.kmMarkMeters, detourMeters: $0.detourMeters, openingHours: $0.openingHours)
        }
        try RouteStore.persist(
            routeId: "route-123", hash: "hash-abc", totalDistanceMeters: 111.2, totalClimbingMeters: 10.0,
            points: points, pois: pois, status: finalStatus.status, context: context)

        let fetched = try context.fetch(FetchDescriptor<RouteModel>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.pois.count, 1)
        XCTAssertEqual(fetched.first?.pois.first?.osmId, 42)
    }
}

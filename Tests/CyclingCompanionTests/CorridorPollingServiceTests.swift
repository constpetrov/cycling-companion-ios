import RoutePersistence
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

/// Routes stubbed responses by URL path suffix, with its own sequenced/repeating-last-response
/// queue per path — lets one transport instance stand in for both the corridor-status and
/// retry endpoints within a single test.
private actor PathRoutedStubTransport: HTTPTransport {
    private var queuesByPathSuffix: [String: [(Int, Data)]]
    private var callCounts: [String: Int] = [:]

    init(queuesByPathSuffix: [String: [(Int, Data)]]) {
        self.queuesByPathSuffix = queuesByPathSuffix
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        guard let key = queuesByPathSuffix.keys.first(where: { path.hasSuffix($0) }) else {
            XCTFail("No stub registered for path \(path)")
            throw CorridorPollingError.unexpectedResponse
        }
        let queue = queuesByPathSuffix[key]!
        let count = callCounts[key, default: 0]
        callCounts[key] = count + 1
        let (statusCode, body) = queue[min(count, queue.count - 1)]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func callCount(forPathSuffix suffix: String) -> Int {
        callCounts[suffix, default: 0]
    }
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
            {"status":"ready","pois":[{"osmId":42,"type":"WATER","name":null,"latitude":52.0005,"longitude":13.0,"kmMarkMeters":55.6,"detourMeters":12.0,"openingHours":"unknown","normalizedOpeningHours":{"alwaysOpen":false,"unknown":true,"intervals":[]}}]}
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

        // AC-29: persist Route + CorridorPOI once ready.
        let storeFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: storeFileURL) }
        let store = RouteStore(fileURL: storeFileURL)

        let points = [
            PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 100.0, cumulativeDistanceMeters: 0)
        ]
        let pois = (finalStatus.pois ?? []).map {
            PersistedPoiInput(
                osmId: $0.osmId, type: $0.type, name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                kmMarkMeters: $0.kmMarkMeters, detourMeters: $0.detourMeters, openingHours: $0.openingHours,
                normalizedOpeningHours: PersistedNormalizedOpeningHours(
                    alwaysOpen: $0.normalizedOpeningHours.alwaysOpen, unknown: $0.normalizedOpeningHours.unknown,
                    intervals: $0.normalizedOpeningHours.intervals.map {
                        PersistedWeeklyOpenInterval(
                            dayOfWeek: $0.dayOfWeek, startMinuteOfDay: $0.startMinuteOfDay,
                            endMinuteOfDay: $0.endMinuteOfDay)
                    }))
        }
        try await store.persist(
            routeId: "route-123", hash: "hash-abc", totalDistanceMeters: 111.2, totalClimbingMeters: 10.0,
            points: points, pois: pois, status: finalStatus.status)

        let fetched = try await store.fetchAll()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.pois.count, 1)
        XCTAssertEqual(fetched.first?.pois.first?.osmId, 42)
        XCTAssertEqual(fetched.first?.pois.first?.normalizedOpeningHours?.unknown, true)
    }

    /// AC-38/AC-39/AC-40 in spec/criteria.md: the full stuck-build flow through one service
    /// instance — polling gives up after the 10-minute timeout window, does not resume on its
    /// own, and only resumes (reaching ready) once the rider taps retry.
    @MainActor
    func testTimesOutStopsPollingThenRetryResumesPollingToReady() async throws {
        let authClient = try await Self.makeAuthClient()

        let buildingBody = #"{"status":"building","pois":null}"#.data(using: .utf8)!
        let readyBody = #"{"status":"ready","pois":[]}"#.data(using: .utf8)!
        let retryBody = #"{"routeId":"route-123","status":"building"}"#.data(using: .utf8)!
        // Timeout window is 10s at a 2s poll interval: 6 "building" fetches (0,2,4,6,8,10s
        // elapsed) exhaust the window; the 7th+ fetch (after retry) returns ready.
        let transport = PathRoutedStubTransport(queuesByPathSuffix: [
            "/corridor": Array(repeating: (200, buildingBody), count: 6) + [(200, readyBody)],
            "/retry": [(200, retryBody)],
        ])
        let clock = FakeClock()
        let service = CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            transport: transport, clock: clock, pollIntervalSeconds: 2.0, timeoutSeconds: 10.0)

        do {
            _ = try await service.pollUntilSettled(routeId: "route-123")
            XCTFail("expected pollUntilSettled to throw .timedOut")
        } catch {
            XCTAssertEqual(error as? CorridorPollingError, .timedOut)
        }

        // AC-38: stopped polling at the timeout boundary — 6 fetches, 5 sleeps (no sleep after
        // the final, timed-out fetch).
        let corridorCallsAfterTimeout = await transport.callCount(forPathSuffix: "/corridor")
        XCTAssertEqual(corridorCallsAfterTimeout, 6)
        let sleepCalls = await clock.sleepCalls
        XCTAssertEqual(sleepCalls, Array(repeating: 2.0, count: 5))

        // AC-39: nothing resumes polling on its own. Structurally guaranteed here — the actor
        // has no timer/task of its own, so without the calls below, no further requests occur.

        let retryResponse = try await service.retry(routeId: "route-123")
        XCTAssertEqual(retryResponse.status, "building")
        let retryCalls = await transport.callCount(forPathSuffix: "/retry")
        XCTAssertEqual(retryCalls, 1)

        // AC-40: resuming polling after retry reaches ready on the very next fetch.
        let finalStatus = try await service.pollUntilSettled(routeId: "route-123")
        XCTAssertEqual(finalStatus.status, "ready")
        let corridorCallsAfterRetry = await transport.callCount(forPathSuffix: "/corridor")
        XCTAssertEqual(corridorCallsAfterRetry, 7)
    }
}

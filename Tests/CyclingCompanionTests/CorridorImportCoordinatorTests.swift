import RoutePersistence
import XCTest

@testable import CyclingCompanion

private struct SingleResponseTransport: HTTPTransport {
    let body: Data
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

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
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

private actor FailingAfterSignInTransport: HTTPTransport {
    private var callCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        if callCount == 1 {
            // sign-in succeeds
            let body = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
                .data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        // importRoute fails
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}

/// task-2.4 validation (RULE-8/RULE-12 in spec/rules.md, AC-6/AC-7).
final class CorridorImportCoordinatorTests: XCTestCase {

    private func sampleRoute() -> ImportedRoute {
        ImportedRoute(
            points: [ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0)],
            totalDistanceMeters: 10_000, totalClimbingMeters: 50, hash: "hash-abc")
    }

    private func freshRouteStore() -> RouteStore {
        RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    private func freshPointer() -> CurrentRoutePointer {
        CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @MainActor
    private func makeCoordinator(transport: HTTPTransport, routeStore: RouteStore, pointer: CurrentRoutePointer, appRouter: AppRouter)
        -> CorridorImportCoordinator
    {
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let service = CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        return CorridorImportCoordinator(
            corridorPollingService: service, routeStore: routeStore, pointer: pointer, appRouter: appRouter,
            lazySignIn: lazySignIn, clock: StoppingClock(stopAfterSeconds: 60))
    }

    // MARK: - Success: immediate persist, pointer, and navigation (AC-6)

    @MainActor
    func testImportSuccessImmediatelyPersistsPointerAndNavigatesBeforeSettling() async throws {
        let signInBody = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
            .data(using: .utf8)!
        let importBody = #"{"routeId":"route-123","status":"building"}"#.data(using: .utf8)!
        let buildingBody = #"{"status":"building","pois":null}"#.data(using: .utf8)!
        let transport = PathRoutedStubTransport(queuesByPathSuffix: [
            "/auth/sign-in": [(200, signInBody)],
            "/routes": [(200, importBody)],
            "/corridor": [(200, buildingBody)],
        ])
        let routeStore = freshRouteStore()
        let pointer = freshPointer()
        let appRouter = AppRouter()
        let coordinator = makeCoordinator(transport: transport, routeStore: routeStore, pointer: pointer, appRouter: appRouter)

        await coordinator.importRoute(sampleRoute())

        // The "/corridor" stub only ever answers "building" (the stopping clock ends
        // the poll after a minute of simulated time), so the background poll Task can never reach its second RouteStore
        // write regardless of scheduling — these assertions hold no matter how far it's run.
        XCTAssertEqual(pointer.routeId, "route-123")
        XCTAssertEqual(appRouter.path, [.corridorMap(routeId: "route-123")])
        let persisted = try await routeStore.fetch(routeId: "route-123")
        XCTAssertEqual(persisted?.status, "building")
        XCTAssertEqual(persisted?.pois.count, 0)
        XCTAssertEqual(persisted?.hash, "hash-abc")
    }

    // MARK: - Failure: nothing persisted, error surfaced (AC-7)

    @MainActor
    func testImportFailureLeavesPointerAndRouteStoreUntouched() async throws {
        let transport = FailingAfterSignInTransport()
        let routeStore = freshRouteStore()
        let pointer = freshPointer()
        let appRouter = AppRouter()
        let coordinator = makeCoordinator(transport: transport, routeStore: routeStore, pointer: pointer, appRouter: appRouter)

        await coordinator.importRoute(sampleRoute())

        XCTAssertNil(pointer.routeId)
        let all = try await routeStore.fetchAll()
        XCTAssertTrue(all.isEmpty)
        XCTAssertEqual(appRouter.path, [])
        XCTAssertNotNil(coordinator.importErrorMessage)
    }

    // MARK: - Eventual settle updates pois exactly once (AC-8/AC-9)

    @MainActor
    func testSettlingUpdatesPOIsExactlyOnce() async throws {
        let signInBody = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
            .data(using: .utf8)!
        let importBody = #"{"routeId":"route-123","status":"building"}"#.data(using: .utf8)!
        let buildingBody = #"{"status":"building","pois":null}"#.data(using: .utf8)!
        let readyBody = """
            {"status":"ready","pois":[{"osmId":42,"type":"WATER","name":null,"latitude":52.0005,"longitude":13.0,"kmMarkMeters":55.6,"detourMeters":12.0,"openingHours":"unknown","normalizedOpeningHours":{"alwaysOpen":false,"unknown":true,"intervals":[]}}]}
            """.data(using: .utf8)!
        let transport = PathRoutedStubTransport(queuesByPathSuffix: [
            "/auth/sign-in": [(200, signInBody)],
            "/routes": [(200, importBody)],
            "/corridor": [(200, buildingBody), (200, readyBody)],
        ])
        let routeStore = freshRouteStore()
        let pointer = freshPointer()
        let appRouter = AppRouter()
        let coordinator = makeCoordinator(transport: transport, routeStore: routeStore, pointer: pointer, appRouter: appRouter)

        let pollTask = await coordinator.importRoute(sampleRoute())
        await pollTask?.value

        XCTAssertEqual(coordinator.pois.count, 1)
        XCTAssertEqual(coordinator.pois.first?.osmId, 42)
        let persisted = try await routeStore.fetch(routeId: "route-123")
        XCTAssertEqual(persisted?.status, "ready")
        XCTAssertEqual(persisted?.pois.count, 1)
    }
}

import RoutePersistence
import XCTest

@testable import CyclingCompanion

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

/// task-2.5 validation (RULE-13/RULE-16 in spec/rules.md, AC-8/AC-9/AC-10/AC-11): Start Ride is
/// enabled identically before and after corridor POIs finish building.
final class CorridorMapScreenTests: XCTestCase {

    private func sampleRoute() -> ImportedRoute {
        ImportedRoute(
            points: [ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0)],
            totalDistanceMeters: 10_000, totalClimbingMeters: 50, hash: "hash-abc")
    }

    @MainActor
    private func makeCoordinator(readyImmediately: Bool) async -> CorridorImportCoordinator {
        let signInBody = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
            .data(using: .utf8)!
        let importBody = #"{"routeId":"route-123","status":"building"}"#.data(using: .utf8)!
        let readyBody = """
            {"status":"ready","pois":[{"osmId":42,"type":"WATER","name":null,"latitude":52.0005,"longitude":13.0,"kmMarkMeters":55.6,"detourMeters":12.0,"openingHours":"unknown","normalizedOpeningHours":{"alwaysOpen":false,"unknown":true,"intervals":[]}}]}
            """.data(using: .utf8)!
        let buildingBody = #"{"status":"building","pois":null}"#.data(using: .utf8)!
        let transport = PathRoutedStubTransport(queuesByPathSuffix: [
            "/auth/sign-in": [(200, signInBody)],
            "/routes": [(200, importBody)],
            "/corridor": readyImmediately ? [(200, readyBody)] : [(200, buildingBody)],
        ])
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let service = CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, transport: transport,
            clock: SystemClock(), pollIntervalSeconds: 0.01, timeoutSeconds: 0.05)
        let coordinator = CorridorImportCoordinator(
            corridorPollingService: service, routeStore: RouteStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")),
            pointer: CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!), appRouter: AppRouter(),
            lazySignIn: LazySignIn(authClient: authClient))

        let pollTask = await coordinator.importRoute(sampleRoute())
        if readyImmediately {
            await pollTask?.value
        }
        return coordinator
    }

    @MainActor
    func testStartRideIsEnabledBeforePOIsExist() async {
        let coordinator = await makeCoordinator(readyImmediately: false)
        XCTAssertTrue(coordinator.pois.isEmpty)

        let screen = CorridorMapScreen(
            viewModel: CorridorMapViewModel(routeId: "route-1", coordinator: coordinator), onStartRide: {})

        XCTAssertTrue(screen.startRideIsEnabled)
    }

    @MainActor
    func testStartRideIsEnabledAfterPOIsExist() async {
        let coordinator = await makeCoordinator(readyImmediately: true)
        XCTAssertFalse(coordinator.pois.isEmpty)

        let screen = CorridorMapScreen(
            viewModel: CorridorMapViewModel(routeId: "route-1", coordinator: coordinator), onStartRide: {})

        XCTAssertTrue(screen.startRideIsEnabled)
    }

    @MainActor
    func testTappingStartRideInvokesTheCallback() {
        var tapped = false
        let coordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(
                baseURL: URL(string: "https://backend.example.com")!,
                authClient: AuthStubClient(baseURL: URL(string: "https://backend.example.com")!)),
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")),
            pointer: CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!), appRouter: AppRouter(),
            lazySignIn: LazySignIn(
                authClient: AuthStubClient(baseURL: URL(string: "https://backend.example.com")!)))
        let screen = CorridorMapScreen(
            viewModel: CorridorMapViewModel(routeId: "route-1", coordinator: coordinator),
            onStartRide: { tapped = true })

        screen.onStartRide()

        XCTAssertTrue(tapped)
    }

    /// task-6.5 (RULE-25, AC-113): a fresh view model for a stored route shows its line and stops
    /// with no import in this process — what happens after a relaunch.
    @MainActor
    func testTheMapLoadsAStoredRouteWithoutAnImport() async throws {
        let store = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await store.persist(
            routeId: "stored", hash: "h", totalDistanceMeters: 1_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52.009, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ],
            pois: [
                PersistedPoiInput(
                    osmId: 7, type: "CAFE", name: "Kaffee", latitude: 52.005, longitude: 13.001, kmMarkMeters: 500,
                    detourMeters: 70, openingHours: nil)
            ], status: "ready")
        let auth = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!)
        let coordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(baseURL: URL(string: "https://backend.example.com")!, authClient: auth),
            routeStore: store, pointer: CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            appRouter: AppRouter(), lazySignIn: LazySignIn(authClient: auth))
        XCTAssertTrue(coordinator.points.isEmpty, "nothing in memory, as after a relaunch")
        let viewModel = CorridorMapViewModel(routeId: "stored", coordinator: coordinator)

        await viewModel.load()

        XCTAssertEqual(viewModel.route?.points.count, 2)
        XCTAssertEqual(viewModel.route?.pois.map(\.osmId), [7])
        XCTAssertEqual(viewModel.state, .ready(stopCount: 1))
        XCTAssertFalse(viewModel.isPolling, "a ready route is not polled again")
    }
}

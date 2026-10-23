import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Scripted backend: corridor status per route (`building` until told otherwise), counts calls.
private actor ScriptedCorridorBackend: HTTPTransport {
    private var statuses: [String: String] = [:]
    private var pois: [String: String] = [:]
    private(set) var statusCalls: [String: Int] = [:]
    private(set) var retryCalls = 0
    var blockStatusCalls = false

    func setStatus(_ status: String, for routeId: String, poisJSON: String = "[]") {
        statuses[routeId] = status
        pois[routeId] = poisJSON
    }

    func setBlocking(_ value: Bool) { blockStatusCalls = value }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let body: String
        if path.hasSuffix("sign-in") {
            body = #"{"token":"t","riderId":"11111111-1111-1111-1111-111111111111"}"#
        } else if path.hasSuffix("/retry") {
            retryCalls += 1
            let routeId = path.components(separatedBy: "/").dropLast().last!
            body = #"{"routeId":"\#(routeId)","status":"building"}"#
        } else if path.hasSuffix("/corridor") {
            let routeId = path.components(separatedBy: "/").dropLast().last!
            statusCalls[routeId, default: 0] += 1
            while blockStatusCalls { try await Task.sleep(nanoseconds: 1_000_000) }
            let status = statuses[routeId] ?? "building"
            body = status == "ready"
                ? #"{"status":"ready","pois":\#(pois[routeId] ?? "[]")}"# : #"{"status":"\#(status)","pois":null}"#
        } else {
            body = "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// task-6.4 (RULE-24): AC-102 to AC-112.
final class CorridorPollingRegistryTests: XCTestCase {

    private let poiJSON = #"[{"osmId":7,"type":"CAFE","name":"Kaffee","latitude":52.0,"longitude":13.0,"kmMarkMeters":500,"detourMeters":50,"openingHours":null,"normalizedOpeningHours":{"alwaysOpen":false,"unknown":true,"intervals":[]}}]"#

    @MainActor
    private func coordinator(
        _ backend: ScriptedCorridorBackend, clock: Clock = ReplayClock()
    ) -> (CorridorImportCoordinator, RouteStore, CurrentRoutePointer) {
        let auth = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: backend)
        let service = CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: auth, transport: backend)
        let store = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let pointer = CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let coordinator = CorridorImportCoordinator(
            corridorPollingService: service, routeStore: store, pointer: pointer, appRouter: AppRouter(),
            lazySignIn: LazySignIn(authClient: auth), clock: clock)
        return (coordinator, store, pointer)
    }

    private static func storeRoute(_ id: String, status: String, in store: RouteStore) async throws {
        try await store.persist(
            routeId: id, hash: "h-\(id)", totalDistanceMeters: 1_000, totalClimbingMeters: nil, points: [], pois: [],
            status: status)
    }

    // MARK: - CorridorState (AC-102 to AC-105)

    func testStateLabels() {
        func route(_ status: String, pois: Int) -> PersistedRoute {
            PersistedRoute(
                id: "r", hash: "h", totalDistanceMeters: 1, totalClimbingMeters: nil, status: status, points: [],
                pois: (0..<pois).map {
                    PersistedPoiInput(
                        osmId: Int64($0), type: "CAFE", name: nil, latitude: 0, longitude: 0, kmMarkMeters: 0,
                        detourMeters: 0, openingHours: nil)
                })
        }
        XCTAssertEqual(CorridorState(route: route("building", pois: 0), isPolling: false), .finding)
        XCTAssertEqual(CorridorState(route: route("ready", pois: 3), isPolling: false), .ready(stopCount: 3))
        XCTAssertEqual(CorridorState(route: route("ready", pois: 0), isPolling: false), .noStops)
        XCTAssertEqual(CorridorState(route: route("failed", pois: 0), isPolling: false), .failed)
        XCTAssertEqual(CorridorState(route: route("failed", pois: 0), isPolling: true), .finding, "retry running")
        XCTAssertEqual(CorridorState.noStops.message, "No stops found within 1.5 km")
        XCTAssertEqual(CorridorState.ready(stopCount: 3).message, "3 stops found")
        XCTAssertTrue(CorridorState.failed.offersRetry)
        XCTAssertFalse(CorridorState.finding.offersRetry)
    }

    // MARK: - No time-based give-up (milestone 8: AC-50, RULE-18)

    @MainActor
    func testAStillBuildingRouteIsNeverStoredAsFailed() async throws {
        let backend = ScriptedCorridorBackend()
        let clock = StoppingClock(stopAfterSeconds: 30 * 60)
        let (coordinator, store, _) = coordinator(backend, clock: clock)
        try await Self.storeRoute("r1", status: "building", in: store)

        let started = await coordinator.ensurePolling(routeId: "r1")
        let poll = try XCTUnwrap(started)
        await poll.value

        let slept = await clock.totalSlept
        XCTAssertGreaterThanOrEqual(slept, 30 * 60, "still polling after 30 simulated minutes")
        let route = try await store.fetch(routeId: "r1")
        XCTAssertEqual(route?.status, "building")
    }

    @MainActor
    func testSettlingBeforeTheTimeoutStoresTheStops() async throws {
        let backend = ScriptedCorridorBackend()
        let (coordinator, store, pointer) = coordinator(backend)
        try await Self.storeRoute("r1", status: "building", in: store)
        pointer.routeId = "r1"
        await backend.setStatus("ready", for: "r1", poisJSON: poiJSON)

        let started = await coordinator.ensurePolling(routeId: "r1")
        let poll = try XCTUnwrap(started)
        await poll.value

        let route = try await store.fetch(routeId: "r1")
        XCTAssertEqual(route?.status, "ready")
        XCTAssertEqual(route?.pois.map(\.osmId), [7])
        XCTAssertEqual(coordinator.pois.map(\.osmId), [7])
    }

    // MARK: - Retry (AC-108, AC-109)

    @MainActor
    func testRetryRestartsTheBuild() async throws {
        let backend = ScriptedCorridorBackend()
        let (coordinator, store, _) = coordinator(backend)
        try await Self.storeRoute("r1", status: "failed", in: store)
        await backend.setStatus("ready", for: "r1")

        let started = await coordinator.retry(routeId: "r1")
        let poll = try XCTUnwrap(started)
        await poll.value

        let retries = await backend.retryCalls
        XCTAssertEqual(retries, 1)
        let route = try await store.fetch(routeId: "r1")
        XCTAssertEqual(route?.status, "ready")
    }

    @MainActor
    func testRetryWhilePollingDoesNothing() async throws {
        let backend = ScriptedCorridorBackend()
        await backend.setBlocking(true)
        let (coordinator, store, _) = coordinator(backend)
        try await Self.storeRoute("r1", status: "building", in: store)
        let started = await coordinator.ensurePolling(routeId: "r1")
        let poll = try XCTUnwrap(started)
        XCTAssertTrue(coordinator.isPolling(routeId: "r1"))

        let second = await coordinator.retry(routeId: "r1")
        let again = await coordinator.ensurePolling(routeId: "r1")

        XCTAssertNil(second)
        XCTAssertNil(again)
        let retries = await backend.retryCalls
        XCTAssertEqual(retries, 0, "no second build request")
        await backend.setStatus("ready", for: "r1")
        await backend.setBlocking(false)
        await poll.value
        XCTAssertFalse(coordinator.isPolling(routeId: "r1"))
    }

    // MARK: - Re-poll (AC-110, AC-111)

    @MainActor
    func testLaunchPollsOnlyRoutesStillBuilding() async throws {
        let backend = ScriptedCorridorBackend()
        await backend.setStatus("ready", for: "building-1")
        let (coordinator, store, _) = coordinator(backend)
        try await Self.storeRoute("building-1", status: "building", in: store)
        try await Self.storeRoute("ready-1", status: "ready", in: store)
        try await Self.storeRoute("failed-1", status: "failed", in: store)

        await coordinator.resumePollingForBuildingRoutes()
        while coordinator.isPolling(routeId: "building-1") { await Task.yield() }

        let calls = await backend.statusCalls
        XCTAssertEqual(Set(calls.keys), ["building-1"])
    }

    @MainActor
    func testOpeningAMapOfAFinishedRouteDoesNotPoll() async throws {
        let (coordinator, store, _) = coordinator(ScriptedCorridorBackend())
        try await Self.storeRoute("r1", status: "ready", in: store)

        let poll = await coordinator.ensurePolling(routeId: "r1")

        XCTAssertNil(poll)
    }

    // MARK: - Superseded route (AC-112)

    @MainActor
    func testALateResultForAnotherRouteOnlyUpdatesThatRoute() async throws {
        let backend = ScriptedCorridorBackend()
        let (coordinator, store, pointer) = coordinator(backend)
        try await Self.storeRoute("old", status: "building", in: store)
        try await Self.storeRoute("current", status: "building", in: store)
        pointer.routeId = "current"
        await backend.setStatus("ready", for: "old", poisJSON: poiJSON)

        let started = await coordinator.ensurePolling(routeId: "old")
        let poll = try XCTUnwrap(started)
        await poll.value

        let old = try await store.fetch(routeId: "old")
        XCTAssertEqual(old?.pois.map(\.osmId), [7])
        let current = try await store.fetch(routeId: "current")
        XCTAssertEqual(current?.status, "building")
        XCTAssertTrue(coordinator.pois.isEmpty, "the current route's displayed stops are untouched")
    }
}

import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// A backend scripted per call: each corridor or Retry request takes the next scripted reply
/// (repeating the last one), where a reply is an HTTP status plus body, or a thrown error.
private actor ScriptedBackend: HTTPTransport {
    enum Reply: Sendable {
        case http(Int, String)
        case fail(URLError.Code)
    }

    private var corridor: [Reply]
    private var retry: [Reply]
    /// Milestone 10: the session can't be renewed — the API answers 401 and refresh is offline.
    private var signInFails: Bool
    private(set) var corridorCalls = 0
    private(set) var retryCalls = 0
    private var retryGate: CheckedContinuation<Void, Never>?
    private var gateRetry = false

    init(corridor: [Reply] = [], retry: [Reply] = [], signInFails: Bool = false) {
        self.corridor = corridor
        self.retry = retry
        self.signInFails = signInFails
    }

    func setCorridor(_ replies: [Reply]) { corridor = replies }
    func setSignInFails(_ fails: Bool) { signInFails = fails }
    func holdRetries() { gateRetry = true }
    func releaseRetries() {
        gateRetry = false
        retryGate?.resume()
        retryGate = nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let reply: Reply
        if path.hasSuffix("auth/refresh") {
            reply = signInFails ? .fail(.notConnectedToInternet)
                : .http(200, #"{"accessToken":"a","refreshToken":"r","riderId":"rider","accessTokenExpiresIn":3600}"#)
        } else if signInFails {
            reply = .http(401, "")
        } else if path.hasSuffix("/retry") {
            retryCalls += 1
            if gateRetry { await withCheckedContinuation { retryGate = $0 } }
            reply = retry[min(retryCalls - 1, retry.count - 1)]
        } else {
            corridorCalls += 1
            reply = corridor[min(corridorCalls - 1, corridor.count - 1)]
        }
        switch reply {
        case .fail(let code):
            throw URLError(code)
        case .http(let status, let body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Milestone 8 phase 4: AC-35 to AC-41, AC-47 to AC-54 (RULE-17 to RULE-19).
final class CorridorStopsRefreshTests: XCTestCase {

    private static let building = ScriptedBackend.Reply.http(200, #"{"status":"building","pois":null}"#)
    private static let failed = ScriptedBackend.Reply.http(200, #"{"status":"failed","pois":null}"#)
    private static let ready = ScriptedBackend.Reply.http(200, #"""
        {"status":"ready","pois":[{"osmId":-7,"type":"CAFE_BAKERY_RESTAURANT","name":"Koffie","latitude":52.0,"longitude":4.9,"kmMarkMeters":500,"detourMeters":50,"openingHours":"unknown","normalizedOpeningHours":{"alwaysOpen":false,"unknown":true,"intervals":[]}}],"coverageRegion":"Netherlands","outsideMeters":2400}
        """#)
    private static let oldStop = PersistedPoiInput(
        osmId: 1, type: "WATER", name: nil, latitude: 52, longitude: 4.9, kmMarkMeters: 100, detourMeters: 10,
        openingHours: nil)

    @MainActor
    private func make(_ backend: ScriptedBackend, clock: Clock = StoppingClock(stopAfterSeconds: 120))
        -> (CorridorImportCoordinator, RouteStore, CurrentRoutePointer)
    {
        let url = URL(string: "https://backend.example.com")!
        let store = RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let pointer = CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let coordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(
                baseURL: url, session: TestAuth.session(baseURL: url, transport: backend)),
            routeStore: store, pointer: pointer, appRouter: AppRouter(), clock: clock)
        return (coordinator, store, pointer)
    }

    private static func seed(_ id: String, status: String, pois: [PersistedPoiInput] = [], in store: RouteStore) async throws {
        try await store.persist(
            routeId: id, hash: "h-\(id)", totalDistanceMeters: 10_000, totalClimbingMeters: nil, points: [], pois: pois,
            status: status, displayName: "Loop")
    }

    // MARK: - Poll loop (task-4.2: AC-47 to AC-50)

    func testPollBackoffStartsAtTwoSecondsAndIsCappedAtFifteen() {
        var backoff = PollBackoff()
        let waits = (0..<9).map { _ in backoff.next() }

        XCTAssertEqual(waits.prefix(5), [2, 3, 4.5, 6.75, 10.125])
        XCTAssertEqual(waits.suffix(4), [15, 15, 15, 15])
    }

    @MainActor
    func testPollIntervalsFollowTheBackoff() async throws {
        let backend = ScriptedBackend(corridor: [Self.building])
        let clock = StoppingClock(stopAfterSeconds: 60)
        let (coordinator, store, _) = make(backend, clock: clock)
        try await Self.seed("r", status: "building", in: store)

        let poll = await coordinator.ensurePolling(routeId: "r")
        await poll?.value

        let sleeps = await clock.sleeps
        XCTAssertEqual(Array(sleeps.prefix(6)), [2, 3, 4.5, 6.75, 10.125, 15])
        XCTAssertTrue(sleeps.allSatisfy { $0 <= 15 })
    }

    /// AC-47, AC-48, AC-49.
    @MainActor
    func testTransientProblemsKeepTheRouteBuildingUntilTheBackendSettles() async throws {
        let backend = ScriptedBackend(corridor: [.fail(.notConnectedToInternet), .fail(.timedOut), .http(503, ""), Self.ready])
        let (coordinator, store, pointer) = make(backend)
        try await Self.seed("r", status: "building", in: store)
        pointer.routeId = "r"

        let poll = await coordinator.ensurePolling(routeId: "r")
        await poll?.value

        let calls = await backend.corridorCalls
        XCTAssertEqual(calls, 4)
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "ready")
        XCTAssertEqual(route?.pois.map(\.osmId), [-7])
        XCTAssertEqual(route?.coverageRegion, "Netherlands")
        XCTAssertEqual(route?.outsideMeters, 2400)
        XCTAssertEqual(route?.displayName, "Loop", "the name survives the update")
    }

    /// AC-49.
    @MainActor
    func testASignInFailureKeepsTheRouteBuilding() async throws {
        let backend = ScriptedBackend(corridor: [Self.ready], signInFails: true)
        let (coordinator, store, _) = make(backend, clock: StoppingClock(stopAfterSeconds: 10))
        try await Self.seed("r", status: "building", in: store)

        let poll = await coordinator.ensurePolling(routeId: "r")
        await poll?.value

        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "building")
    }

    /// AC-50.
    @MainActor
    func testOnlyABackendFailedAnswerStoresFailed() async throws {
        let backend = ScriptedBackend(corridor: [Self.building, Self.failed])
        let (coordinator, store, _) = make(backend)
        try await Self.seed("r", status: "building", pois: [Self.oldStop], in: store)

        let poll = await coordinator.ensurePolling(routeId: "r")
        await poll?.value

        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "failed")
        XCTAssertEqual(route?.pois.map(\.osmId), [1], "a failed answer keeps the stored stops")
    }

    @MainActor
    func testANotFoundAnswerStopsPollingAndChangesNothing() async throws {
        let backend = ScriptedBackend(corridor: [.http(404, "")])
        let (coordinator, store, _) = make(backend)
        try await Self.seed("r", status: "building", in: store)

        let poll = await coordinator.ensurePolling(routeId: "r")
        await poll?.value

        let calls = await backend.corridorCalls
        XCTAssertEqual(calls, 1)
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "building")
        XCTAssertFalse(coordinator.isPolling(routeId: "r"))
    }

    @MainActor
    func testPausingStopsPollingAndKeepsTheRouteBuilding() async throws {
        let backend = ScriptedBackend(corridor: [Self.building])
        let gate = GatedClock()
        let (coordinator, store, _) = make(backend, clock: gate)
        try await Self.seed("r", status: "building", in: store)
        let poll = await coordinator.ensurePolling(routeId: "r")

        coordinator.pauseAllPolls()
        await poll?.value
        let callsAtPause = await backend.corridorCalls
        await gate.release()  // even if the clock lets sleeps through, a paused app asks nothing more
        await coordinator.refreshCurrentRoute()
        await coordinator.resumePollingForBuildingRoutes()

        XCTAssertFalse(coordinator.isPolling(routeId: "r"))
        let callsAfter = await backend.corridorCalls
        XCTAssertEqual(callsAfter, callsAtPause, "no request while paused")
        XCTAssertLessThanOrEqual(callsAtPause, 1)
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "building")
    }

    /// AC-47 to AC-50: however long the problems last, a route is never stored as failed.
    @MainActor
    func testOnlyTransientProblemsNeverStoreFailed() async throws {
        let backend = ScriptedBackend(corridor: [
            .fail(.notConnectedToInternet), .fail(.timedOut), .http(503, ""), .http(408, ""), .http(429, ""),
            .http(200, #"{"rideId":"x"}"#),
        ])
        let (coordinator, store, _) = make(backend, clock: StoppingClock(stopAfterSeconds: 20 * 60))
        try await Self.seed("r", status: "building", pois: [Self.oldStop], in: store)

        await coordinator.ensurePolling(routeId: "r")?.value

        let calls = await backend.corridorCalls
        XCTAssertGreaterThan(calls, 6, "kept asking through every kind of problem")
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "building")
        XCTAssertEqual(route?.pois.map(\.osmId), [1])
    }

    @MainActor
    func testResumingRightAfterPausingStartsAFreshPoll() async throws {
        let backend = ScriptedBackend(corridor: [Self.building])
        let (coordinator, store, _) = make(backend, clock: GatedClock())
        try await Self.seed("r", status: "building", in: store)
        let first = await coordinator.ensurePolling(routeId: "r")

        coordinator.pauseAllPolls()
        await coordinator.appBecameActive()
        await first?.value  // the cancelled poll finishes after the new one registered

        XCTAssertTrue(coordinator.isPolling(routeId: "r"), "the fresh poll is still registered")
        coordinator.pauseAllPolls()
    }

    @MainActor
    func testNoPollStartsWhileTheAppIsInTheBackground() async throws {
        let backend = ScriptedBackend(corridor: [Self.building])
        let (coordinator, store, _) = make(backend, clock: GatedClock())
        try await Self.seed("r", status: "building", in: store)

        coordinator.pauseAllPolls()
        await coordinator.resumePollingForBuildingRoutes()

        XCTAssertFalse(coordinator.isPolling(routeId: "r"))
        await coordinator.appBecameActive()
        XCTAssertTrue(coordinator.isPolling(routeId: "r"))
        coordinator.pauseAllPolls()
    }

    // MARK: - Launch and foreground refresh (task-4.3: AC-35 to AC-41)

    /// AC-35, AC-36, AC-37.
    @MainActor
    func testARefreshAsksOnceAndReplacesStopsAndCoverage() async throws {
        let backend = ScriptedBackend(corridor: [Self.ready])
        let (coordinator, store, pointer) = make(backend)
        try await Self.seed("r", status: "ready", pois: [Self.oldStop], in: store)
        pointer.routeId = "r"

        await coordinator.refreshCurrentRoute()

        let calls = await backend.corridorCalls
        XCTAssertEqual(calls, 1)
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.pois.map(\.osmId), [-7])
        XCTAssertEqual(route?.outsideMeters, 2400)
        XCTAssertEqual(coordinator.pois.map(\.osmId), [-7])
    }

    @MainActor
    func testARefreshWithNoCurrentRouteAsksNothing() async throws {
        let backend = ScriptedBackend(corridor: [Self.ready])
        let (coordinator, _, _) = make(backend)

        await coordinator.refreshCurrentRoute()

        let calls = await backend.corridorCalls
        XCTAssertEqual(calls, 0)
    }

    /// AC-38, AC-39, AC-40.
    @MainActor
    func testARefreshThatFailsKeepsTheStoredRoute() async throws {
        for reply in [ScriptedBackend.Reply.fail(.notConnectedToInternet), .fail(.timedOut), .http(500, ""), .http(404, "")] {
            let backend = ScriptedBackend(corridor: [reply])
            let (coordinator, store, pointer) = make(backend)
            try await Self.seed("r", status: "ready", pois: [Self.oldStop], in: store)
            pointer.routeId = "r"

            await coordinator.refreshCurrentRoute()

            let route = try await store.fetch(routeId: "r")
            XCTAssertEqual(route?.status, "ready", "\(reply)")
            XCTAssertEqual(route?.pois.map(\.osmId), [1], "\(reply)")
        }
        let backend = ScriptedBackend(corridor: [Self.ready], signInFails: true)
        let (coordinator, store, pointer) = make(backend)
        try await Self.seed("r", status: "ready", pois: [Self.oldStop], in: store)
        pointer.routeId = "r"
        await coordinator.refreshCurrentRoute()
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.pois.map(\.osmId), [1], "sign-in failure")
    }

    /// AC-41: a route left `failed` by the milestone 7 app recovers.
    @MainActor
    func testARouteStoredFailedBecomesReadyOnRefresh() async throws {
        let backend = ScriptedBackend(corridor: [Self.ready])
        let (coordinator, store, pointer) = make(backend)
        try await Self.seed("r", status: "failed", in: store)
        pointer.routeId = "r"

        await coordinator.refreshCurrentRoute()

        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "ready")
        XCTAssertEqual(CorridorState(route: route!, isPolling: false), .ready(stopCount: 1))
    }

    @MainActor
    func testARefreshAnsweredBuildingStartsPollingAndKeepsTheStops() async throws {
        let backend = ScriptedBackend(corridor: [Self.building, Self.ready])
        let (coordinator, store, pointer) = make(backend)
        try await Self.seed("r", status: "ready", pois: [Self.oldStop], in: store)
        pointer.routeId = "r"

        await coordinator.refreshCurrentRoute()

        XCTAssertTrue(coordinator.isPolling(routeId: "r"))
        let whileBuilding = try await store.fetch(routeId: "r")
        XCTAssertEqual(whileBuilding?.status, "building")
        XCTAssertEqual(whileBuilding?.pois.map(\.osmId), [1])
        await coordinator.ensurePolling(routeId: "r")?.value
        while coordinator.isPolling(routeId: "r") { await Task.yield() }
        let settled = try await store.fetch(routeId: "r")
        XCTAssertEqual(settled?.status, "ready")
    }

    // MARK: - Retry (task-4.4: AC-51 to AC-54)

    /// AC-51, AC-52.
    @MainActor
    func testADoubleTappedRetrySendsOneRequestAndShowsInFlight() async throws {
        let backend = ScriptedBackend(corridor: [Self.ready], retry: [.http(200, #"{"routeId":"r","status":"ready"}"#)])
        await backend.holdRetries()
        let (coordinator, store, _) = make(backend)
        try await Self.seed("r", status: "failed", in: store)

        let first = Task { await coordinator.retry(routeId: "r") }
        while await backend.retryCalls == 0 { await Task.yield() }
        XCTAssertTrue(coordinator.retryInFlight.contains("r"))
        let second = await coordinator.retry(routeId: "r")
        await backend.releaseRetries()
        await first.value?.value

        XCTAssertNil(second)
        let calls = await backend.retryCalls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(coordinator.retryInFlight.contains("r"))
    }

    /// AC-53.
    @MainActor
    func testARetryWithNoConnectionShowsNoConnectionAndKeepsTheState() async throws {
        let backend = ScriptedBackend(retry: [.fail(.notConnectedToInternet)])
        let (coordinator, store, _) = make(backend)
        try await Self.seed("r", status: "failed", in: store)

        await coordinator.retry(routeId: "r")

        XCTAssertEqual(coordinator.retryErrors["r"], .noConnection)
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "failed")
    }

    /// AC-54.
    @MainActor
    func testARetryWithAServerErrorShowsServerProblemAndClearsOnTheNextAttempt() async throws {
        let backend = ScriptedBackend(corridor: [Self.ready], retry: [.http(500, ""), .http(200, #"{"routeId":"r","status":"ready"}"#)])
        let (coordinator, store, _) = make(backend)
        try await Self.seed("r", status: "failed", in: store)

        await coordinator.retry(routeId: "r")
        XCTAssertEqual(coordinator.retryErrors["r"], .server)
        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "failed")

        await coordinator.retry(routeId: "r")?.value
        XCTAssertNil(coordinator.retryErrors["r"])
    }

    // MARK: - Stored coverage (task-4.1)

    func testARoutesFileFromBeforeThisMilestoneStillLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let old = #"{"r":{"id":"r","hash":"h","totalDistanceMeters":1,"status":"ready","points":[],"pois":[],"displayName":"Old"}}"#
        try Data(old.utf8).write(to: url)

        let route = try await RouteStore(fileURL: url).fetch(routeId: "r")

        XCTAssertEqual(route?.displayName, "Old")
        XCTAssertNil(route?.coverageRegion)
        XCTAssertNil(route?.outsideMeters)
    }

    func testUpdateChangesStatusStopsAndCoverageInOneStepAndKeepsTheRest() async throws {
        let store = RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await Self.seed("r", status: "building", pois: [Self.oldStop], in: store)

        try await store.update(routeId: "r", status: "ready", coverageRegion: "Netherlands", outsideMeters: 10)
        try await store.update(routeId: "missing", status: "ready")

        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.status, "ready")
        XCTAssertEqual(route?.pois.map(\.osmId), [1], "stops kept when none are given")
        XCTAssertEqual(route?.displayName, "Loop")
        XCTAssertEqual(route?.outsideMeters, 10)
        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 1, "an unknown route isn't created")
        let reread = try await RouteStore(fileURL: store.fileURLForTests).fetch(routeId: "r")
        XCTAssertEqual(reread?.status, "ready", "written to disk, not only the cache")
    }
}

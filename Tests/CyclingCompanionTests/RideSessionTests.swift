import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Routes requests by path suffix; a single stubbed sign-in response plus a configurable
/// advisor-decision response. Tracks call counts per path so tests can assert whether the
/// remote Advisor was ever attempted.
private actor StubAdvisorTransport: HTTPTransport {
    private let decisionStatusCode: Int
    private let decisionBody: Data
    private(set) var decisionCallCount = 0

    init(decisionStatusCode: Int = 200, decisionBody: Data) {
        self.decisionStatusCode = decisionStatusCode
        self.decisionBody = decisionBody
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        if path.hasSuffix("sign-in") {
            let body = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#
                .data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        decisionCallCount += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: decisionStatusCode, httpVersion: nil, headerFields: nil)!
        return (decisionBody, response)
    }
}

/// task-1.3 through task-1.5 validation (RULE-1/RULE-4/RULE-5/RULE-6/RULE-12/RULE-14/RULE-15/
/// RULE-16 in spec/rules.md, AC-1/AC-2/AC-9/AC-10/AC-11, AC-12 through AC-15, AC-24, AC-26):
/// the cadence/force-check loop, the advisor-chain wiring (both Local and remote), and the
/// per-cycle `RouteStore` re-read.
final class RideSessionTests: XCTestCase {

    private static let routeId = "route-1"

    private func flatRoute() -> [ResampledPoint] {
        [
            ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
            ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
        ]
    }

    @MainActor
    private func freshRideTracker(route: [ResampledPoint], fixes: [LocationFix] = []) -> RideTracker {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return RideTracker(
            rideId: "ride-1", routeId: Self.routeId, startTime: Date(timeIntervalSince1970: 0), route: route,
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
    }

    /// A `RouteStore` with a single persisted route under `routeId`, carrying `pois`.
    @MainActor
    private func routeStore(pois: [PersistedPoiInput]) async -> RouteStore {
        let store = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try? await store.persist(
            routeId: Self.routeId, hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil,
            points: [], pois: pois, status: "ready")
        return store
    }

    @MainActor
    private func makeSession(
        clock: Clock, tracker: RideTracker? = nil, routeStore: RouteStore? = nil, notifier: Notifier? = nil,
        snapshotIntervalSeconds: TimeInterval = 60, decisionLog: DecisionLog? = nil, advisorClient: AdvisorClient? = nil,
        stopTypeFilter: StopTypeFilter = .allEnabled
    ) async -> RideSession {
        let tracker = tracker ?? freshRideTracker(route: flatRoute())
        let engine = FeatureEngine(rideTracker: tracker, route: flatRoute(), clock: clock)
        let notifier = notifier ?? Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog())
        let store: RouteStore
        if let routeStore {
            store = routeStore
        } else {
            store = await self.routeStore(pois: [])
        }
        return RideSession(
            rideTracker: tracker, featureEngine: engine, clock: clock, routeId: Self.routeId, routeStore: store,
            decisionLog: decisionLog ?? DecisionLog(), notifier: notifier, snapshotIntervalSeconds: snapshotIntervalSeconds,
            pollGranularitySeconds: 1.0, advisorClient: advisorClient, stopTypeFilter: stopTypeFilter)
    }

    /// Builds a real `AdvisorClient` backed by `StubAdvisorTransport` — matching this project's
    /// convention of faking at the transport layer, not the service layer (`CorridorPollingService`'s
    /// own tests do the same).
    @MainActor
    private func advisorClient(
        decisionStatusCode: Int = 200, decisionBody: Data
    ) -> (client: AdvisorClient, transport: StubAdvisorTransport) {
        let transport = StubAdvisorTransport(decisionStatusCode: decisionStatusCode, decisionBody: decisionBody)
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        let client = AdvisorClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, lazySignIn: lazySignIn,
            transport: transport)
        return (client, transport)
    }

    private func candidate(osmId: Int64 = 1, kmMarkMeters: Double = 1_000, detourMeters: Double = 300) -> PersistedPoiInput
    {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: "Café Sample", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: kmMarkMeters, detourMeters: detourMeters, openingHours: nil)
    }

    // MARK: - Cadence (AC-12)

    @MainActor
    func testStepDoesNotRunACycleBeforeTheCadenceElapses() async throws {
        let clock = ReplayClock()
        let session = await makeSession(clock: clock, snapshotIntervalSeconds: 60)

        for _ in 0..<59 {
            let ran = try await session.step()
            XCTAssertFalse(ran)
        }
    }

    @MainActor
    func testStepRunsACycleExactlyWhenTheCadenceElapses() async throws {
        let clock = ReplayClock()
        let session = await makeSession(clock: clock, snapshotIntervalSeconds: 60)

        for _ in 0..<59 {
            try await session.step()
        }
        let ranAtSixty = try await session.step()

        XCTAssertTrue(ranAtSixty)
    }

    @MainActor
    func testCadenceResetsAfterACycleRuns() async throws {
        let clock = ReplayClock()
        let session = await makeSession(clock: clock, snapshotIntervalSeconds: 60)

        for _ in 0..<60 {
            try await session.step()
        }
        let ranImmediatelyAfter = try await session.step()

        XCTAssertFalse(ranImmediatelyAfter, "the cadence counter must reset once a cycle runs, not keep accumulating")
    }

    // MARK: - Force check (AC-24)

    @MainActor
    func testForceNextCheckRunsACycleImmediatelyWithoutWaitingOutTheCadence() async throws {
        let clock = ReplayClock()
        let session = await makeSession(clock: clock, snapshotIntervalSeconds: 60)

        await session.forceNextCheck()
        let ran = try await session.step()

        XCTAssertTrue(ran)
    }

    @MainActor
    func testForceNextCheckIsConsumedOnlyOnce() async throws {
        let clock = ReplayClock()
        let session = await makeSession(clock: clock, snapshotIntervalSeconds: 60)

        await session.forceNextCheck()
        try await session.step()
        let ranAgainImmediately = try await session.step()

        XCTAssertFalse(ranAgainImmediately, "a single forceNextCheck() must not force every subsequent step")
    }

    // MARK: - Advisor chain wiring (AC-12/AC-13/AC-14/AC-15)

    /// Two on-route fixes, the second 700s after the first (past Guardrail Gate's 10-minute
    /// post-stop-quiet window — `timeSinceLastStopSeconds` treats ride start itself as the
    /// reference point until a real stop occurs, so a *single*-fix fixture would read as "the
    /// rider just stopped 0 seconds ago" and always be rejected).
    @MainActor
    private func trackerPastTheQuietWindow() async -> RideTracker {
        let fixes = [
            LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 1_000)),
            LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 1_700)),
        ]
        let tracker = freshRideTracker(route: flatRoute(), fixes: fixes)
        await tracker.start()
        return tracker
    }

    @MainActor
    func testNoCycleRunsBeforeAnyLocationFixHasArrived() async throws {
        // runCycle() is a no-op without a track sample to read "now" from; step()'s own
        // cadence/force bookkeeping is unaffected either way.
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        let store = await routeStore(pois: [candidate()])
        let session = await makeSession(clock: clock, routeStore: store, notifier: notifier, snapshotIntervalSeconds: 60)

        await session.forceNextCheck()
        try await session.step()

        let posted = await scheduling.addedRequests
        XCTAssertTrue(posted.isEmpty)
    }

    @MainActor
    func testQualifyingStopAheadPostsANotificationWhenAuthorized() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        let store = await routeStore(pois: [candidate()])
        let session = await makeSession(
            clock: clock, tracker: tracker, routeStore: store, notifier: notifier, snapshotIntervalSeconds: 60)

        await session.forceNextCheck()
        try await session.step()

        let posted = await scheduling.addedRequests
        XCTAssertEqual(posted.count, 1)
    }

    @MainActor
    func testRejectedVerdictPostsNothingAndTheLoopContinues() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        // Detour far beyond the 2km cap — Guardrail Gate rejects even though a qualifying stop
        // is ahead and Local Advisor suggests it.
        let store = await routeStore(pois: [candidate(detourMeters: 5_000)])
        let session = await makeSession(
            clock: clock, tracker: tracker, routeStore: store, notifier: notifier, snapshotIntervalSeconds: 60)

        await session.forceNextCheck()
        try await session.step()
        let postedAfterReject = await scheduling.addedRequests
        XCTAssertTrue(postedAfterReject.isEmpty)

        // The loop keeps running afterward — a second forced cycle doesn't throw or stall.
        await session.forceNextCheck()
        let ranAgain = try await session.step()
        XCTAssertTrue(ranAgain)
    }

    // MARK: - Per-cycle RouteStore re-read (AC-26)

    @MainActor
    func testSuggestionsCatchUpOncePOIsFinishBuildingAfterTheRideAlreadyStarted() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        // Corridor still "building" — no POIs yet, same shape CorridorImportCoordinator's
        // first RouteStore write leaves behind (RULE-12).
        let store = await routeStore(pois: [])
        let session = await makeSession(
            clock: clock, tracker: tracker, routeStore: store, notifier: notifier, snapshotIntervalSeconds: 60)

        await session.forceNextCheck()
        try await session.step()
        let postedBeforePOIsExist = await scheduling.addedRequests
        XCTAssertTrue(postedBeforePOIsExist.isEmpty, "no candidates exist yet, so nothing should be suggested")

        // Corridor finishes building mid-ride — CorridorImportCoordinator's second write.
        try await store.persist(
            routeId: Self.routeId, hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil, points: [],
            pois: [candidate()], status: "ready")

        await session.forceNextCheck()
        try await session.step()
        let postedAfterPOIsArrive = await scheduling.addedRequests
        XCTAssertEqual(postedAfterPOIsArrive.count, 1, "the very next cycle must pick up the newly-arrived POI")
    }

    // MARK: - Remote Advisor wiring (task-1.5, AC-1/AC-2/AC-9/AC-10/AC-11)

    @MainActor
    func testZeroCandidatesSkipsTheRemoteCallEntirely() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let clock = ReplayClock()
        let store = await routeStore(pois: [])  // zero candidates
        let (client, transport) = advisorClient(decisionBody: #"{"suggest":false}"#.data(using: .utf8)!)
        let session = await makeSession(clock: clock, tracker: tracker, routeStore: store, advisorClient: client)

        await session.forceNextCheck()
        try await session.step()

        let decisionCalls = await transport.decisionCallCount
        XCTAssertEqual(decisionCalls, 0, "the remote Advisor must never be called when there are no candidates")
    }

    @MainActor
    func testAStopOfATypeTurnedOffInSettingsIsNeverACandidate() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let store = await routeStore(pois: [candidate()])
        let (client, transport) = advisorClient(decisionBody: #"{"suggest":false}"#.data(using: .utf8)!)
        let session = await makeSession(
            clock: ReplayClock(), tracker: tracker, routeStore: store, advisorClient: client,
            stopTypeFilter: StopTypeFilter { ["CAFE_BAKERY_RESTAURANT"] })

        await session.forceNextCheck()
        try await session.step()

        let decisionCalls = await transport.decisionCallCount
        XCTAssertEqual(decisionCalls, 0, "the only stop is a café and cafés are off, so there is nothing to ask about")
    }

    @MainActor
    func testSharedRideFactoryForwardsTheRemoteAdvisorIntoTheSession() async throws {
        let store = await routeStore(pois: [candidate()])
        let route = PersistedRoute(
            id: Self.routeId, hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil, status: "ready",
            points: flatRoute().map {
                PersistedPointInput(
                    latitude: $0.latitude, longitude: $0.longitude, elevationMeters: $0.elevationMeters,
                    cumulativeDistanceMeters: $0.cumulativeDistanceMeters)
            }, pois: [candidate()])
        let rideStore = RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let log = DecisionLog()
        let (client, transport) = advisorClient(decisionBody: #"{"suggest":false}"#.data(using: .utf8)!)
        let (tracker, session) = await makeTrackerAndSession(
            rideId: "factory-ride", routeId: Self.routeId, startTime: Date(timeIntervalSince1970: 1_000),
            route: route,
            locationSource: ReplayLocationSource(fixes: [
                LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 1_000)),
                LocationFix(latitude: 52.0, longitude: 13.0, speedMetersPerSecond: 5, timestamp: Date(timeIntervalSince1970: 1_700)),
            ]), sensorSource: ReplaySensorSource(samples: []), clock: ReplayClock(),
            rideStore: rideStore, routeStore: store, decisionLog: log,
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log), advisorClient: client)
        await tracker.start()
        await session.forceNextCheck()
        try await session.step()

        let callCount = await transport.decisionCallCount
        XCTAssertEqual(callCount, 1)
        let decisions = await log.advisorDecisions
        XCTAssertEqual(decisions.first?.suggest, false)
    }

    @MainActor
    func testASuccessfulRemoteDecisionIsUsedAndLocalAdvisorIsNotInvoked() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        let candidateStop = candidate(osmId: 1)
        let store = await routeStore(pois: [candidateStop])
        let decisionLog = DecisionLog()
        let (client, _) = advisorClient(
            decisionBody: #"""
                {"suggest":true,"stopId":"1","urgency":"normal","reason":"remote-reason","message":"remote-message"}
                """#.data(using: .utf8)!)
        let session = await makeSession(
            clock: clock, tracker: tracker, routeStore: store, notifier: notifier, decisionLog: decisionLog,
            advisorClient: client)

        await session.forceNextCheck()
        try await session.step()

        let logged = await decisionLog.advisorDecisions
        XCTAssertEqual(logged.count, 1, "exactly one decision must be logged per cycle")
        XCTAssertEqual(logged.first?.reason, "remote-reason", "Local Advisor would never produce this reason string")
        let posted = await scheduling.addedRequests
        XCTAssertEqual(posted.count, 1)
    }

    @MainActor
    func testANilRemoteResultFallsBackToLocalAdvisor() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        let store = await routeStore(pois: [candidate()])
        let decisionLog = DecisionLog()
        // Unparseable response: AdvisorClient.requestDecision returns nil.
        let (client, _) = advisorClient(decisionBody: "not json".data(using: .utf8)!)
        let session = await makeSession(
            clock: clock, tracker: tracker, routeStore: store, notifier: notifier, decisionLog: decisionLog,
            advisorClient: client)

        await session.forceNextCheck()
        try await session.step()

        let logged = await decisionLog.advisorDecisions
        XCTAssertEqual(logged.count, 1, "exactly one decision must be logged per cycle, from the Local Advisor fallback")
        XCTAssertEqual(logged.first?.stopId, "1", "the logged decision must be Local Advisor's (candidate's osmId), not a remote one")
        let posted = await scheduling.addedRequests
        XCTAssertEqual(posted.count, 1, "the fallback decision must still be able to post a notification")
    }

    @MainActor
    func testAnInventedStopIsBlockedWithoutFallingBackToLocalAdvisor() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let clock = ReplayClock()
        let store = await routeStore(pois: [candidate(osmId: 1)])
        let decisionLog = DecisionLog()
        // suggest:true, but stop_id "999" isn't on the candidate list (which only has "1").
        let (client, _) = advisorClient(
            decisionBody: #"""
                {"suggest":true,"stopId":"999","urgency":"normal","reason":"remote-reason","message":"remote-message"}
                """#.data(using: .utf8)!)
        let session = await makeSession(
            clock: clock, tracker: tracker, routeStore: store, notifier: notifier, decisionLog: decisionLog,
            advisorClient: client)

        await session.forceNextCheck()
        try await session.step()

        let logged = await decisionLog.advisorDecisions
        XCTAssertEqual(
            logged.count, 1,
            "Guardrail Gate blocking an invented stop must not trigger a second, Local Advisor decision this cycle")
        XCTAssertEqual(logged.first?.stopId, "999", "the logged decision must still be the remote one, not a fallback")
        let posted = await scheduling.addedRequests
        XCTAssertTrue(posted.isEmpty, "an invented stop must never reach the rider as a notification")
    }

    // MARK: - Trace ids (milestone 9 task-3.3, RULE-32, AC-75, AC-76, review hotspot 2)

    private static let remoteTraceId = "0f8a3c1e-2b4d-4e6f-8a9b-1c2d3e4f5a6b"

    @MainActor
    private func ledgerAfterOneCycle(decisionStatusCode: Int = 200, decisionBody: String, candidates: [PersistedPoiInput])
        async throws -> SuggestionLedger
    {
        let tracker = await trackerPastTheQuietWindow()
        let store = await routeStore(pois: candidates)
        let (client, _) = advisorClient(decisionStatusCode: decisionStatusCode, decisionBody: Data(decisionBody.utf8))
        let session = await makeSession(clock: ReplayClock(), tracker: tracker, routeStore: store, advisorClient: client)
        await session.forceNextCheck()
        try await session.step()
        return await session.suggestionLedger()
    }

    /// AC-75.
    @MainActor
    func testARemoteSuggestionKeepsItsTraceId() async throws {
        let ledger = try await ledgerAfterOneCycle(
            decisionBody: #"{"suggest":true,"stopId":"1","urgency":"low","reason":"r","message":"Coffee?","traceId":"\#(Self.remoteTraceId)"}"#,
            candidates: [candidate(osmId: 1)])

        XCTAssertEqual(ledger.current?.traceId, Self.remoteTraceId)
        XCTAssertEqual(ledger.finalResponses.first?.traceId, Self.remoteTraceId)
    }

    /// RULE-32: a remote decision the Guardrail Gate rejects makes no suggestion, so no trace id lands anywhere.
    @MainActor
    func testARemoteDecisionRejectedByTheGateLeavesNoTracedSuggestion() async throws {
        let ledger = try await ledgerAfterOneCycle(
            decisionBody: #"{"suggest":true,"stopId":"999","urgency":"low","reason":"r","message":"m","traceId":"\#(Self.remoteTraceId)"}"#,
            candidates: [candidate(osmId: 1)])

        XCTAssertTrue(ledger.suggestions.isEmpty)
    }

    /// AC-76: the backend answered 502 (its trace exists, but the app never sees an id); LocalAdvisor's
    /// suggestion carries none.
    @MainActor
    func testAFallbackSuggestionAfterARemoteFailureHasNoTraceId() async throws {
        let ledger = try await ledgerAfterOneCycle(
            decisionStatusCode: 502, decisionBody: #"{"status":502}"#, candidates: [candidate(osmId: 1)])

        let suggestion = try XCTUnwrap(ledger.current, "LocalAdvisor still suggests the candidate")
        XCTAssertNil(suggestion.traceId)
        XCTAssertNil(ledger.finalResponses.first?.traceId)
    }

    /// A backend from before milestone 9 sends no traceId; the remote suggestion simply has none.
    @MainActor
    func testARemoteSuggestionFromAnOlderBackendHasNoTraceId() async throws {
        let ledger = try await ledgerAfterOneCycle(
            decisionBody: #"{"suggest":true,"stopId":"1","urgency":"low","reason":"r","message":"Coffee?"}"#,
            candidates: [candidate(osmId: 1)])

        XCTAssertNotNil(ledger.current)
        XCTAssertNil(ledger.current?.traceId)
    }

    // MARK: - Suggestion ledger and stream (task-4.3, RULE-15/RULE-16, AC-45, AC-46, AC-64, AC-65)

    @MainActor
    private func sessionWithRemoteSuggestion(stopId: Int64 = 1, transportOut: inout StubAdvisorTransport?) async
        -> RideSession
    {
        let tracker = await trackerPastTheQuietWindow()
        let notifier = Notifier(
            scheduling: FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true), log: DecisionLog())
        let store = await routeStore(pois: [candidate(osmId: stopId)])
        let (client, transport) = advisorClient(
            decisionBody: #"{"suggest":true,"stopId":"\#(stopId)","urgency":"low","reason":"r","message":"Coffee?"}"#
                .data(using: .utf8)!)
        transportOut = transport
        return await makeSession(
            clock: ReplayClock(), tracker: tracker, routeStore: store, notifier: notifier, advisorClient: client)
    }

    @MainActor
    func testAnApprovedSuggestionIsPublishedOnceAndRecordedInTheLedger() async throws {
        var transport: StubAdvisorTransport?
        let session = await sessionWithRemoteSuggestion(transportOut: &transport)
        var iterator = session.approvedSuggestions.makeAsyncIterator()

        await session.forceNextCheck()
        try await session.step()

        let published = await iterator.next()
        XCTAssertEqual(published?.stopId, 1)
        XCTAssertEqual(published?.message, "Coffee?")
        let ledger = await session.suggestionLedger()
        XCTAssertEqual(ledger.current?.id, published?.id)
    }

    @MainActor
    func testARejectedVerdictPublishesNothing() async throws {
        let tracker = await trackerPastTheQuietWindow()
        let store = await routeStore(pois: [candidate(osmId: 1)])
        let (client, _) = advisorClient(
            decisionBody: #"{"suggest":true,"stopId":"999","urgency":"low","reason":"r","message":"m"}"#.data(using: .utf8)!)
        let session = await makeSession(clock: ReplayClock(), tracker: tracker, routeStore: store, advisorClient: client)

        await session.forceNextCheck()
        try await session.step()

        let ledger = await session.suggestionLedger()
        XCTAssertNil(ledger.current, "an invented stop is rejected by the Guardrail Gate and never published")
        XCTAssertTrue(ledger.suggestions.isEmpty)
    }

    @MainActor
    func testADeclinedStopIsNeverSentToTheAdvisorAgain() async throws {
        var transport: StubAdvisorTransport?
        let session = await sessionWithRemoteSuggestion(transportOut: &transport)
        await session.forceNextCheck()
        try await session.step()
        let ledgerAfterFirst = await session.suggestionLedger()
        let suggestion = try XCTUnwrap(ledgerAfterFirst.current)
        let callsBefore = await transport!.decisionCallCount

        await session.respond(.declined, to: suggestion.id, at: Date())
        await session.forceNextCheck()
        try await session.step()

        let callsAfter = await transport!.decisionCallCount
        XCTAssertEqual(callsAfter, callsBefore, "the only candidate was declined, so there is nothing to ask about")
        let ledger = await session.suggestionLedger()
        XCTAssertNil(ledger.current)
        XCTAssertEqual(ledger.suggestions.count, 1, "the declined stop is not suggested again")
    }
}

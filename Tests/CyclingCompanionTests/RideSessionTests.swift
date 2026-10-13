import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-1.3 through task-1.5 validation (RULE-1/RULE-4/RULE-5/RULE-6 in spec/rules.md, AC-12
/// through AC-15, AC-24, AC-26): the cadence/force-check loop, the advisor-chain wiring, and
/// the per-cycle `RouteStore` re-read.
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
        snapshotIntervalSeconds: TimeInterval = 60
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
            decisionLog: DecisionLog(), notifier: notifier, snapshotIntervalSeconds: snapshotIntervalSeconds,
            pollGranularitySeconds: 1.0)
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
}

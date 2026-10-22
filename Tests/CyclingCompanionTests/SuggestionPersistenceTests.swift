import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-4.4 (RULE-17): AC-66, AC-69 — suggestion state saved with the ride checkpoint, written
/// only by the tracker, restored on resume, and compatible with rides saved by older builds.
final class SuggestionPersistenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func suggestion(_ id: String, stop: Int64, kmMark: Double = 5_000) -> ApprovedSuggestion {
        ApprovedSuggestion(
            id: id, stopId: stop, name: "Stop \(stop)", type: "CAFE", latitude: 52, longitude: 13,
            kmMarkMeters: kmMark, detourMeters: 100, message: "Coffee?", suggestedAt: t0)
    }

    private func ledgerWithHistory() -> SuggestionLedger {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))
        ledger.respond(.declined, to: "a", at: t0 + 10)
        ledger.approve(suggestion("b", stop: 2))
        ledger.respond(.accepted, to: "b", at: t0 + 20)
        ledger.approve(suggestion("c", stop: 3))
        return ledger
    }

    private func freshStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    func testLedgerSurvivesTheRoundTrip() {
        let ledger = ledgerWithHistory()

        let restored = SuggestionLedger(persisted: ledger.persisted)

        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.current?.id, "c")
        XCTAssertEqual(restored.declinedStopIds, [1])
        XCTAssertEqual(restored.response(to: "b")?.answer, .accepted)
    }

    /// AC-69: a checkpoint written before this milestone has no suggestion state and still loads.
    func testARideSavedByAnOlderBuildStillDecodes() throws {
        let legacy = #"""
            {"id":"ride-1","routeId":"route-1","startTime":0,"totalDistanceMeters":100,"totalMovingTimeSeconds":20,"track":[]}
            """#
        let ride = try JSONDecoder().decode(PersistedRide.self, from: Data(legacy.utf8))

        XCTAssertNil(ride.suggestionState)
        let ledger = ride.suggestionState.map(SuggestionLedger.init(persisted:)) ?? SuggestionLedger()
        XCTAssertNil(ledger.current)
        XCTAssertTrue(ledger.declinedStopIds.isEmpty)
        XCTAssertTrue(ledger.answers.isEmpty)
    }

    @MainActor
    private func trackerAndSession(rideStore: RideStore, fixes: [LocationFix] = []) async -> (RideTracker, RideSession) {
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let route = PersistedRoute(
            id: "route-1", hash: "h", totalDistanceMeters: 1_000, totalClimbingMeters: nil, status: "ready",
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52.009, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ], pois: [])
        try? await routeStore.persist(
            routeId: route.id, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
            totalClimbingMeters: nil, points: route.points, pois: [], status: "ready")
        let log = DecisionLog()
        return await makeTrackerAndSession(
            rideId: "ride-1", routeId: "route-1", startTime: t0, route: route,
            locationSource: ReplayLocationSource(fixes: fixes), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore, routeStore: routeStore, decisionLog: log,
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log))
    }

    /// RULE-17: an answer is checkpointed at once, by the tracker, together with the track.
    @MainActor
    func testAnAnswerIsCheckpointedImmediatelyAlongsideTheTrack() async throws {
        let rideStore = freshStore()
        let fix = LocationFix(latitude: 52.001, longitude: 13, speedMetersPerSecond: 5, timestamp: t0 + 5)
        let (tracker, session) = await trackerAndSession(rideStore: rideStore, fixes: [fix])
        await tracker.start()  // one fix → one checkpoint with the track
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))
        await session.restoreLedger(ledger)

        await session.respond(.declined, to: "a", at: t0 + 30)

        let fetched = try await rideStore.fetch(rideId: "ride-1")
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(stored.track.count, 1, "the track is still there")
        XCTAssertEqual(stored.suggestionState?.answers.first?.answer, "DECLINED")
        XCTAssertEqual(stored.suggestionState?.declinedStopIds, [1])
        XCTAssertNil(stored.endTime)
    }

    /// AC-66: kill and resume restores declined stops, the current card and the answers.
    @MainActor
    func testResumeRestoresTheSuggestionState() async throws {
        let rideStore = freshStore()
        let (tracker, session) = await trackerAndSession(rideStore: rideStore)
        let history = ledgerWithHistory()
        await session.restoreLedger(history)
        await tracker.checkpointNow()

        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 1_000, totalClimbingMeters: nil,
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52.009, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 1_000),
            ], pois: [], status: "ready")
        let coordinator = RideCoordinator()
        let log = DecisionLog()
        let resumer = RideResumer(
            rideStore: rideStore, routeStore: routeStore, rideCoordinator: coordinator, decisionLog: log,
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log))

        await resumer.resumeIfNeeded()

        let resumed = try XCTUnwrap(coordinator.activeRide)
        let restored = await resumed.session.suggestionLedger()
        XCTAssertEqual(restored, history)
        coordinator.end(resumed)
    }
}

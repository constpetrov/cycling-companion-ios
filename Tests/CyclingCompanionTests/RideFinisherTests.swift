import RoutePersistence
import XCTest

@testable import CyclingCompanion

private struct AlwaysSucceedsTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let body: Data
        if path.hasSuffix("sign-in") {
            body = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#.data(using: .utf8)!
        } else {
            body = #"{"rideId":"22222222-2222-2222-2222-222222222222"}"#.data(using: .utf8)!
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// Records each ride-ingest request together with whether the summary was already showing when
/// it was sent, so tests can check ordering (summary first, upload second) and duplicate uploads.
private actor RecordingTransport: HTTPTransport {
    private let rideCoordinator: RideCoordinator
    /// `true` per ingest request if the summary was already showing when it was sent.
    private(set) var homeShownAtIngest: [Bool] = []

    init(rideCoordinator: RideCoordinator) {
        self.rideCoordinator = rideCoordinator
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if !request.url!.path.hasSuffix("sign-in") {
            let isHome = await MainActor.run { () -> Bool in
                if case .summary = rideCoordinator.presentation { return true }
                return false
            }
            homeShownAtIngest.append(isHome)
        }
        return try await AlwaysSucceedsTransport().data(for: request)
    }
}

/// task-3.1 validation (RULE-9/RULE-16 in spec/rules.md, AC-16).
final class RideFinisherTests: XCTestCase {

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func makeFinisher(
        rideRecorder: RideFinalizing, rideCoordinator: RideCoordinator, rideStore: RideStore,
        transport: HTTPTransport = AlwaysSucceedsTransport()
    ) -> RideFinisher {
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, lazySignIn: lazySignIn,
            transport: transport)
        let pendingQueue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return RideFinisher(
            rideRecorder: rideRecorder, rideCoordinator: rideCoordinator, decisionLog: DecisionLog(), rideStore: rideStore,
            uploader: RideUploader(ingestClient: ingestClient, queue: pendingQueue))
    }

    @MainActor
    private func freshTracker(rideStore: RideStore) -> RideTracker {
        RideTracker(
            rideId: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            route: [
                ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100, cumulativeDistanceMeters: 0),
                ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: 100, cumulativeDistanceMeters: 10_000),
            ], locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(), rideStore: rideStore)
    }

    @MainActor
    private func freshSession(tracker: RideTracker, routeStore: RouteStore) -> RideSession {
        RideSession(
            rideTracker: tracker, featureEngine: FeatureEngine(rideTracker: tracker, route: [], clock: ReplayClock()),
            clock: ReplayClock(), routeId: "route-1", routeStore: routeStore, decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: DecisionLog()))
    }

    @MainActor
    func testFinishRideCancelsBothBackgroundTasks() async {
        let rideStore = freshRideStore()
        let tracker = freshTracker(rideStore: rideStore)
        let session = freshSession(
            tracker: tracker,
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        let trackingTask = Task<Void, Never> { try? await Task.sleep(nanoseconds: .max) }
        let sessionTask = Task<Void, Never> { try? await Task.sleep(nanoseconds: .max) }
        let liveRide = LiveRide(tracker: tracker, session: session, trackingTask: trackingTask, sessionTask: sessionTask)
        let rideCoordinator = RideCoordinator()
        let finisher = makeFinisher(rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator, rideStore: rideStore)

        await finisher.finishRide(liveRide)

        XCTAssertTrue(trackingTask.isCancelled)
        XCTAssertTrue(sessionTask.isCancelled)
    }

    @MainActor
    func testFinishRidePersistsTheFinalRideAndNavigatesHome() async throws {
        let rideStore = freshRideStore()
        let tracker = freshTracker(rideStore: rideStore)
        let session = freshSession(
            tracker: tracker,
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        let trackingTask = Task<Void, Never> {}
        let sessionTask = Task<Void, Never> {}
        let liveRide = LiveRide(tracker: tracker, session: session, trackingTask: trackingTask, sessionTask: sessionTask)
        let rideCoordinator = RideCoordinator()
        let finisher = makeFinisher(rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator, rideStore: rideStore)

        await finisher.finishRide(liveRide)

        let persisted = try await rideStore.fetch(rideId: "ride-1")
        XCTAssertNotNil(persisted?.endTime, "finalize must set a real endTime, not leave the checkpoint's nil")
        XCTAssertNil(rideCoordinator.activeRide)
        guard case .summary(.saved(let saved)) = rideCoordinator.presentation else {
            return XCTFail("expected the summary of the saved ride")
        }
        XCTAssertEqual(saved.id, "ride-1")
    }

    @MainActor
    private func liveRideWithIdleTasks(rideStore: RideStore) -> LiveRide {
        let tracker = freshTracker(rideStore: rideStore)
        let session = freshSession(
            tracker: tracker,
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
        return LiveRide(
            tracker: tracker, session: session, trackingTask: Task<Void, Never> {}, sessionTask: Task<Void, Never> {})
    }

    @MainActor
    func testFinishRideNavigatesHomeBeforeTheUploadIsSent() async {
        let rideStore = freshRideStore()
        let liveRide = liveRideWithIdleTasks(rideStore: rideStore)
        let rideCoordinator = RideCoordinator()
        rideCoordinator.activate(liveRide)
        let transport = RecordingTransport(rideCoordinator: rideCoordinator)
        let finisher = makeFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator, rideStore: rideStore,
            transport: transport)

        await finisher.finishRide(liveRide)

        let homeShown = await transport.homeShownAtIngest
        XCTAssertEqual(homeShown, [true], "the rider must not wait on the live screen for the network")
    }

    @MainActor
    func testADoubleTapOnFinishFinalizesAndUploadsTheRideOnce() async {
        let rideStore = freshRideStore()
        let liveRide = liveRideWithIdleTasks(rideStore: rideStore)
        let rideCoordinator = RideCoordinator()
        rideCoordinator.activate(liveRide)
        let transport = RecordingTransport(rideCoordinator: rideCoordinator)
        let finisher = makeFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator, rideStore: rideStore,
            transport: transport)

        async let first = finisher.finishRide(liveRide)
        async let second = finisher.finishRide(liveRide)
        _ = await (first, second)

        let uploads = await transport.homeShownAtIngest.count
        XCTAssertEqual(uploads, 1)
    }


    /// AC-84: saving fails → summary says not saved, no upload, and the unfinished checkpoint
    /// stays so the ride resumes on next launch.
    @MainActor
    func testAFailedSaveSkipsTheUploadAndKeepsTheUnfinishedRide() async throws {
        let rideStore = freshRideStore()
        try await rideStore.persist(
            PersistedRide(
                id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: nil,
                totalDistanceMeters: 500, totalMovingTimeSeconds: 100, track: []))
        let liveRide = liveRideWithIdleTasks(rideStore: rideStore)
        let rideCoordinator = RideCoordinator()
        rideCoordinator.activate(liveRide)
        let transport = RecordingTransport(rideCoordinator: rideCoordinator)
        let finisher = makeFinisher(
            rideRecorder: FailingRecorder(), rideCoordinator: rideCoordinator, rideStore: rideStore,
            transport: transport)

        let outcome = await finisher.finishRide(liveRide)

        guard case .notSaved = outcome else { return XCTFail("expected .notSaved") }
        guard case .summary(.notSaved) = rideCoordinator.presentation else {
            return XCTFail("the summary must say the ride wasn't saved")
        }
        let uploads = await transport.homeShownAtIngest.count
        XCTAssertEqual(uploads, 0, "nothing is uploaded for a ride that wasn't saved")
        let stored = try await rideStore.fetch(rideId: "ride-1")
        XCTAssertNil(stored?.endTime, "the checkpoint stays unfinished so the ride resumes")
    }

    /// AC-77: a successful finish ends on the summary of the saved ride.
    @MainActor
    func testASuccessfulFinishShowsTheSavedRidesSummary() async {
        let rideStore = freshRideStore()
        let liveRide = liveRideWithIdleTasks(rideStore: rideStore)
        let rideCoordinator = RideCoordinator()
        rideCoordinator.activate(liveRide)
        let finisher = makeFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator, rideStore: rideStore)

        let outcome = await finisher.finishRide(liveRide)

        guard case .saved(let ride) = outcome, case .summary(.saved(let shown)) = rideCoordinator.presentation else {
            return XCTFail("expected the saved ride's summary")
        }
        XCTAssertEqual(ride.id, shown.id)
        XCTAssertNotNil(ride.endTime)
    }
}

private struct FailingRecorder: RideFinalizing {
    struct WriteFailed: Error {}

    func finalize(
        rideId: String, routeId: String, startTime: Date, endTime: Date, totalDistanceMeters: Double,
        totalMovingTimeSeconds: Double, track: [PersistedRideSample], suggestionState: PersistedSuggestionState?
    ) async throws -> PersistedRide {
        throw WriteFailed()
    }
}

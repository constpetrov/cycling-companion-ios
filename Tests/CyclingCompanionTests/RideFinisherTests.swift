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

/// task-3.1 validation (RULE-9/RULE-16 in spec/rules.md, AC-16).
final class RideFinisherTests: XCTestCase {

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    @MainActor
    private func makeFinisher(rideRecorder: RideRecorder, appRouter: AppRouter, rideStore: RideStore) -> RideFinisher {
        let transport = AlwaysSucceedsTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient, lazySignIn: lazySignIn,
            transport: transport)
        let pendingQueue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return RideFinisher(
            rideRecorder: rideRecorder, appRouter: appRouter, decisionLog: DecisionLog(), rideStore: rideStore,
            rideIngestClient: ingestClient, pendingUploadQueue: pendingQueue)
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
        let appRouter = AppRouter()
        let finisher = makeFinisher(rideRecorder: RideRecorder(rideStore: rideStore), appRouter: appRouter, rideStore: rideStore)

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
        let appRouter = AppRouter()
        let finisher = makeFinisher(rideRecorder: RideRecorder(rideStore: rideStore), appRouter: appRouter, rideStore: rideStore)

        await finisher.finishRide(liveRide)

        let persisted = try await rideStore.fetch(rideId: "ride-1")
        XCTAssertNotNil(persisted?.endTime, "finalize must set a real endTime, not leave the checkpoint's nil")
        XCTAssertEqual(appRouter.currentScreen, .home)
    }
}

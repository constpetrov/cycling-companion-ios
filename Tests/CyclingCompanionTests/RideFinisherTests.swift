import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.1 validation (RULE-9/RULE-16 in spec/rules.md, AC-16).
final class RideFinisherTests: XCTestCase {

    private func freshRideStore() -> RideStore {
        RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
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
        let finisher = RideFinisher(rideRecorder: RideRecorder(rideStore: rideStore), appRouter: appRouter)

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
        let finisher = RideFinisher(rideRecorder: RideRecorder(rideStore: rideStore), appRouter: appRouter)

        await finisher.finishRide(liveRide)

        let persisted = try await rideStore.fetch(rideId: "ride-1")
        XCTAssertNotNil(persisted?.endTime, "finalize must set a real endTime, not leave the checkpoint's nil")
        XCTAssertEqual(appRouter.currentScreen, .home)
    }
}

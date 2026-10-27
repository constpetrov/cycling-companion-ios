import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Milestone 10 task-4.5 (RULE-37): AC-110, AC-116, AC-123, AC-124.
@MainActor
final class SessionStateTests: XCTestCase {

    // MARK: - The gate (AC-110, AC-124)

    func testSignedInNeverShowsSignIn() {
        for phase in [RideCoordinator.Phase.idle, .preparing, .resuming, .active, .finishing] {
            XCTAssertFalse(SessionGate.showsSignIn(status: .signedIn(riderId: "r"), ridePhase: phase, rideOnScreen: false))
        }
    }

    /// AC-110.
    func testWithoutASessionAtHomeSignInIsShown() {
        XCTAssertTrue(SessionGate.showsSignIn(status: .signedOut, ridePhase: .idle, rideOnScreen: false))
        XCTAssertTrue(SessionGate.showsSignIn(status: .ended(.expired), ridePhase: .idle, rideOnScreen: false))
    }

    /// AC-123: a session that ends mid-ride never interrupts the ride.
    func testAnEndedSessionWaitsWhileARideIsUnderway() {
        for phase in [RideCoordinator.Phase.preparing, .resuming, .active, .finishing] {
            XCTAssertFalse(
                SessionGate.showsSignIn(status: .ended(.expired), ridePhase: phase, rideOnScreen: true), "\(phase)")
            XCTAssertFalse(
                SessionGate.showsSignIn(status: .signedOut, ridePhase: phase, rideOnScreen: false), "\(phase)")
        }
    }

    /// AC-124: the summary stays until the rider closes it; then sign-in appears.
    func testSignInWaitsForTheRideSummaryToClose() {
        XCTAssertFalse(SessionGate.showsSignIn(status: .ended(.expired), ridePhase: .idle, rideOnScreen: true))
        XCTAssertTrue(SessionGate.showsSignIn(status: .ended(.expired), ridePhase: .idle, rideOnScreen: false))
    }

    // MARK: - SessionState

    func testEventsUpdateTheStatus() {
        let state = SessionState(status: .signedOut)

        state.apply(.signedIn(riderId: "rider-1"))
        XCTAssertEqual(state.status, .signedIn(riderId: "rider-1"))
        XCTAssertTrue(state.isSignedIn)

        state.apply(.ended(.disabled(message: "This account is disabled")))
        XCTAssertEqual(state.status, .ended(.disabled(message: "This account is disabled")))
        XCTAssertEqual(state.endedMessage, "This account is disabled")

        state.signedOut()
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.endedMessage)
    }

    func testTheStateFollowsTheSessionsEvents() async throws {
        let backend = FakeTokenBackend(refreshAnswer: .refused(status: 401, code: "SESSION_INVALID", message: "ended"))
        let session = AuthSession(
            api: AuthAPIClient(baseURL: TestAuth.baseURL, transport: backend),
            tokenStore: InMemoryTokenStore(token: "r0"), transport: backend, accessToken: "expired")
        let state = SessionState(status: .signedIn(riderId: "rider-1"))
        state.observe(session.events)

        _ = try? await session.send(URLRequest(url: TestAuth.baseURL.appendingPathComponent("api/v1/x")))
        for _ in 0..<50 where state.status != .ended(.expired) {
            await Task.yield()
        }

        XCTAssertEqual(state.status, .ended(.expired))
        XCTAssertEqual(state.endedMessage, "Your session has ended. Please sign in again.")
    }

    // MARK: - Launch (AC-116, AC-110)

    private func dependencies(token: String?) -> AppDependencies {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let memory = AccountMemory(defaults: defaults)
        memory.remember(riderId: "rider-9", email: "anna@example.com")
        return AppDependencies(
            baseURL: TestAuth.baseURL, demoAccessToken: nil,
            routeStore: RouteStore(fileURL: directory.appendingPathComponent("routes.json")),
            rideStore: RideStore(fileURL: directory.appendingPathComponent("rides.json")),
            pendingUploadsFileURL: directory.appendingPathComponent("pending.json"),
            pointer: CurrentRoutePointer(defaults: defaults), notificationScheduling: PreviewNotificationScheduling(),
            keepScreenOnPreference: InMemoryKeepScreenOnPreference(), idleTimer: NoIdleTimer(),
            stopTypeSettings: StopTypeSettings(defaults: defaults), tokenStore: InMemoryTokenStore(token: token),
            accountMemory: memory, transport: OfflineTransport())
    }

    /// AC-116.
    func testAStoredRefreshTokenStartsSignedIn() {
        XCTAssertEqual(dependencies(token: "stored").sessionState.status, .signedIn(riderId: "rider-9"))
    }

    /// AC-110.
    func testNoStoredTokenStartsSignedOut() {
        XCTAssertEqual(dependencies(token: nil).sessionState.status, .signedOut)
    }

    // MARK: - The ride keeps going (AC-123)

    /// With the session ended, the Advisor call fails quietly (nil) without reaching the API, so
    /// RideSession falls back to LocalAdvisor exactly as on any remote failure.
    func testAnAdvisorCallWithAnEndedSessionFallsBackQuietly() async {
        let backend = FakeTokenBackend()
        let session = AuthSession(
            api: AuthAPIClient(baseURL: TestAuth.baseURL, transport: backend), tokenStore: InMemoryTokenStore(),
            transport: backend)
        let client = AdvisorClient(baseURL: TestAuth.baseURL, session: session)

        let decision = await client.requestDecision(
            rideId: "ride-1", routeId: "route-1",
            snapshot: FeatureSnapshot(
                timestamp: Date(), speedTrend: -0.02, cadenceDrop: nil, timeSinceLastStopSeconds: 4_000,
                remainingEffortMeters: 10_000),
            candidates: [])

        XCTAssertNil(decision)
        let apiCalls = await backend.apiCalls
        XCTAssertEqual(apiCalls, 0)
    }
}

import Foundation
import RoutePersistence

@testable import CyclingCompanion

/// Milestone 10 (RULE-44): sessions for tests of the API clients.
enum TestAuth {
    static let baseURL = URL(string: "https://backend.example.com")!

    /// A session that already holds an access token, as if the rider had signed in; it refreshes
    /// only after a 401.
    static func session(baseURL: URL = baseURL, transport: HTTPTransport = OfflineTransport()) -> AuthSession {
        AuthSession(
            api: AuthAPIClient(baseURL: baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(token: "test-refresh-token"), transport: transport,
            accessToken: "test-access-token")
    }
}

/// Milestone 10 (RULE-44): the account graph behind the sign-in screens and Settings, on real stores
/// in temporary files and a scripted transport.
@MainActor
struct AccountHarness {
    let api: AuthAPIClient
    let session: AuthSession
    let tokenStore: InMemoryTokenStore
    let memory: AccountMemory
    let state: SessionState
    let routeStore: RouteStore
    let rideStore: RideStore
    let queue: PendingRideUploadQueue
    let pointer: CurrentRoutePointer
    let coordinator: CorridorImportCoordinator
    let rideCoordinator: RideCoordinator
    let appRouter: AppRouter
    let actions: AccountActions

    init(transport: HTTPTransport, refreshToken: String? = nil, accessToken: String? = nil,
         status: SessionState.Status = .signedOut)
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        api = AuthAPIClient(baseURL: TestAuth.baseURL, transport: transport)
        tokenStore = InMemoryTokenStore(token: refreshToken)
        session = AuthSession(api: api, tokenStore: tokenStore, transport: transport, accessToken: accessToken)
        memory = AccountMemory(defaults: defaults)
        state = SessionState(status: status)
        state.observe(session.events)
        routeStore = RouteStore(fileURL: directory.appendingPathComponent("routes.json"))
        rideStore = RideStore(fileURL: directory.appendingPathComponent("rides.json"))
        queue = PendingRideUploadQueue(fileURL: directory.appendingPathComponent("pending.json"))
        pointer = CurrentRoutePointer(defaults: defaults)
        rideCoordinator = RideCoordinator()
        appRouter = AppRouter()
        coordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(baseURL: TestAuth.baseURL, session: session),
            routeStore: routeStore, pointer: pointer, appRouter: appRouter)
        actions = AccountActions(
            api: api, session: session, sessionState: state, accountMemory: memory,
            eraser: LocalDataEraser(
                routeStore: routeStore, rideStore: rideStore, pendingUploadQueue: queue, pointer: pointer,
                corridorImportCoordinator: coordinator, appRouter: appRouter, session: session),
            pendingUploadQueue: queue, rideCoordinator: rideCoordinator)
    }

    /// One route, one finished ride and one queued upload, as a rider would leave them.
    func seedLocalData(rideId: String = "ride-1") async throws {
        try await routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 1_000, totalClimbingMeters: nil, points: [], pois: [],
            status: "ready")
        pointer.routeId = "route-1"
        try await rideStore.persist(PersistedRide(
            id: rideId, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 3_600), totalDistanceMeters: 1_000, totalMovingTimeSeconds: 3_600,
            track: []))
        try await queue.enqueue(RideIngestRequestPayload(
            routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 3_600),
            totalDistanceMeters: 1_000, totalMovingTimeSeconds: 3_600, stopsTaken: 0, outcome: "TYPICAL",
            featureSnapshots: []), id: rideId)
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }
}

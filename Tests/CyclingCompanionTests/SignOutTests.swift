import XCTest

@testable import CyclingCompanion

/// Records sign-out requests and fails or succeeds them.
private actor SignOutBackend: HTTPTransport {
    private let fails: Bool
    private(set) var signOutCalls = 0

    init(fails: Bool) {
        self.fails = fails
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url!.path.hasSuffix("auth/sign-out") {
            signOutCalls += 1
            if fails { throw URLError(.notConnectedToInternet) }
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
}

/// Milestone 10 task-5.2 (RULE-38, RULE-39): AC-127, AC-128, AC-141.
@MainActor
final class SignOutTests: XCTestCase {

    /// AC-128.
    func testSignOutErasesEveryLocalStoreAndTheToken() async throws {
        let backend = SignOutBackend(fails: false)
        let h = AccountHarness(transport: backend, refreshToken: "r1", accessToken: "a1", status: .signedIn(riderId: "rider-1"))
        h.memory.remember(riderId: "rider-1", email: "anna@example.com")
        try await h.seedLocalData()

        await h.actions.signOut()

        let routes = try await h.routeStore.fetchAll()
        let rides = try await h.rideStore.fetchAll()
        let queued = try await h.queue.fetchAllOldestFirst()
        XCTAssertTrue(routes.isEmpty)
        XCTAssertTrue(rides.isEmpty)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertNil(h.pointer.routeId)
        XCTAssertNil(try h.tokenStore.load())
        XCTAssertNil(h.memory.riderId)
        XCTAssertEqual(h.state.status, .signedOut)
        let calls = await backend.signOutCalls
        XCTAssertEqual(calls, 1)
    }

    /// AC-141.
    func testAnOfflineSignOutStillSignsOutLocallyAndIsNotRetried() async throws {
        let backend = SignOutBackend(fails: true)
        let h = AccountHarness(transport: backend, refreshToken: "r1", accessToken: "a1", status: .signedIn(riderId: "rider-1"))
        try await h.seedLocalData()

        await h.actions.signOut()

        let rides = try await h.rideStore.fetchAll()
        XCTAssertTrue(rides.isEmpty)
        XCTAssertNil(try h.tokenStore.load())
        XCTAssertEqual(h.state.status, .signedOut)
        let calls = await backend.signOutCalls
        XCTAssertEqual(calls, 1)
    }

    /// AC-127: the warning counts queued uploads.
    func testTheWarningCountsQueuedUploads() async throws {
        let h = AccountHarness(transport: SignOutBackend(fails: false))
        let before = await h.actions.unuploadedRideCount()
        XCTAssertEqual(before, 0)

        try await h.seedLocalData(rideId: "ride-1")
        try await h.queue.enqueue(RideIngestRequestPayload(
            routeId: "route-1", startTime: Date(), endTime: Date(), totalDistanceMeters: 1, totalMovingTimeSeconds: 1,
            stopsTaken: 0, outcome: "TYPICAL", featureSnapshots: []), id: "ride-2")

        let count = await h.actions.unuploadedRideCount()
        XCTAssertEqual(count, 2)
    }

    func testTheCorridorCoordinatorForgetsItsRoute() async throws {
        let h = AccountHarness(transport: SignOutBackend(fails: false))
        try await h.seedLocalData()
        let revision = h.coordinator.storeRevision

        await h.actions.signOut()

        XCTAssertTrue(h.coordinator.points.isEmpty)
        XCTAssertGreaterThan(h.coordinator.storeRevision, revision)
    }
}

import XCTest

@testable import CyclingCompanion

/// A backend whose sign-in returns `riderId`, and which records every request path.
private actor SwitchBackend: HTTPTransport {
    private let riderId: String
    private(set) var paths: [String] = []

    init(riderId: String) {
        self.riderId = riderId
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        paths.append(path)
        let body: String
        if path.hasSuffix("auth/sign-in") {
            body = #"{"accessToken":"a-new","refreshToken":"r-new","riderId":"\#(riderId)","accessTokenExpiresIn":3600}"#
        } else if path.hasSuffix("api/v1/rides") {
            body = #"{"rideId":"server-ride"}"#
        } else {
            body = ""
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: path.hasSuffix("sign-out") ? 204 : 200,
                                                 httpVersion: nil, headerFields: nil)!)
    }
}

/// Milestone 10 task-5.3 (RULE-40): AC-130 to AC-132.
@MainActor
final class AccountSwitchTests: XCTestCase {

    private func harness(signingInAs riderId: String, lastRider: String?) async throws -> (AccountHarness, SwitchBackend) {
        let backend = SwitchBackend(riderId: riderId)
        let h = AccountHarness(transport: backend, status: .ended(.expired))
        if let lastRider {
            h.memory.remember(riderId: lastRider, email: "last@example.com")
        }
        try await h.seedLocalData()
        return (h, backend)
    }

    /// AC-130: the same rider keeps the data, and the queued ride is uploaded.
    func testTheSameRiderKeepsTheDataAndUploadsTheQueue() async throws {
        let backend = SwitchBackend(riderId: "rider-1")
        let h = AccountHarness(transport: backend, status: .ended(.expired))
        h.memory.remember(riderId: "rider-1", email: "anna@example.com")
        try await h.seedLocalData()
        let ingestClient = RideIngestClient(baseURL: TestAuth.baseURL, session: h.session)
        let actions = AccountActions(
            api: h.api, session: h.session, sessionState: h.state, accountMemory: h.memory,
            eraser: LocalDataEraser(
                routeStore: h.routeStore, rideStore: h.rideStore, pendingUploadQueue: h.queue, pointer: h.pointer,
                corridorImportCoordinator: h.coordinator, appRouter: h.appRouter, session: h.session),
            pendingUploadQueue: h.queue, rideCoordinator: h.rideCoordinator,
            retryQueuedUploads: {
                await PendingRideUploadRetrier(pendingUploadQueue: h.queue, rideIngestClient: ingestClient,
                                               rideStore: h.rideStore).retryPendingUploads()
            })

        let result = try await actions.signIn(email: "anna@example.com", password: "a long password")

        XCTAssertEqual(result, .signedIn)
        let routes = try await h.routeStore.fetchAll()
        let rides = try await h.rideStore.fetchAll()
        let queued = try await h.queue.fetchAllOldestFirst()
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(rides.count, 1)
        XCTAssertTrue(queued.isEmpty, "the queued ride was uploaded")
        let paths = await backend.paths
        XCTAssertTrue(paths.contains { $0.hasSuffix("api/v1/rides") })
    }

    /// AC-131: a different rider is asked first, then the data goes.
    func testADifferentRiderMustConfirmAndThenTheDataIsErased() async throws {
        let (h, _) = try await harness(signingInAs: "rider-2", lastRider: "rider-1")

        let result = try await h.actions.signIn(email: "bob@example.com", password: "a long password")

        guard case let .confirmSwitch(pending) = result else { return XCTFail("expected a confirmation, got \(result)") }
        XCTAssertEqual(pending.unuploadedRides, 1)
        XCTAssertNil(try h.tokenStore.load(), "nothing is stored before the rider confirms")
        let ridesBefore = try await h.rideStore.fetchAll()
        XCTAssertEqual(ridesBefore.count, 1)

        try await h.actions.confirm(pending)
        await h.waitUntil { h.state.isSignedIn }

        let rides = try await h.rideStore.fetchAll()
        let queued = try await h.queue.fetchAllOldestFirst()
        XCTAssertTrue(rides.isEmpty)
        XCTAssertTrue(queued.isEmpty)
        XCTAssertEqual(try h.tokenStore.load(), "r-new")
        XCTAssertEqual(h.memory.riderId, "rider-2")
        XCTAssertEqual(h.state.status, .signedIn(riderId: "rider-2"))
    }

    /// AC-132: declining keeps the data, ends the new session and stays signed out.
    func testDecliningKeepsTheDataAndRevokesTheNewSession() async throws {
        let (h, backend) = try await harness(signingInAs: "rider-2", lastRider: "rider-1")
        let result = try await h.actions.signIn(email: "bob@example.com", password: "a long password")
        guard case let .confirmSwitch(pending) = result else { return XCTFail("expected a confirmation") }

        await h.actions.decline(pending)

        let rides = try await h.rideStore.fetchAll()
        XCTAssertEqual(rides.count, 1)
        XCTAssertNil(try h.tokenStore.load())
        XCTAssertEqual(h.memory.riderId, "rider-1")
        XCTAssertFalse(h.state.isSignedIn)
        let paths = await backend.paths
        XCTAssertEqual(paths.last.map { $0.hasSuffix("auth/sign-out") }, true)
    }

    func testAPhoneWithNoDataNeedsNoConfirmation() async throws {
        let backend = SwitchBackend(riderId: "rider-2")
        let h = AccountHarness(transport: backend)
        h.memory.remember(riderId: "rider-1", email: "last@example.com")

        let result = try await h.actions.signIn(email: "bob@example.com", password: "a long password")

        XCTAssertEqual(result, .signedIn)
    }

    /// The form shows the confirmation and its warning names the rides.
    func testTheFormAsksBeforeSwitching() async throws {
        let (h, _) = try await harness(signingInAs: "rider-2", lastRider: "rider-1")
        let model = AuthFlowModel(actions: h.actions)
        model.email = "bob@example.com"
        model.password = "a long password"

        await model.submit()

        XCTAssertNotNil(model.pendingSwitch)
        XCTAssertTrue(model.switchWarning.contains("1 ride not uploaded yet will be lost"))
        await model.declineSwitch()
        XCTAssertNil(model.pendingSwitch)
    }
}

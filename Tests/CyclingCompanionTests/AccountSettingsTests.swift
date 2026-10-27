import XCTest

@testable import CyclingCompanion

/// Answers the account endpoints with scripted statuses and records each request.
private actor AccountBackend: HTTPTransport {
    struct Sent: Sendable {
        let path: String
        let authorization: String?
        let body: [String: String]
    }

    private let passwordStatus: Int
    private let deleteStatus: Int
    private(set) var sent: [Sent] = []

    init(passwordStatus: Int = 204, deleteStatus: Int = 204) {
        self.passwordStatus = passwordStatus
        self.deleteStatus = deleteStatus
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let body = (try? JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())) ?? [:]
        sent.append(Sent(path: path, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let status = path.hasSuffix("account/password") ? passwordStatus : path.hasSuffix("account/delete") ? deleteStatus : 204
        let errorBody = #"{"error":"PASSWORD_INCORRECT","message":"Password is incorrect"}"#
        return (Data((status == 401 ? errorBody : "").utf8),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Milestone 10 task-5.4 (RULE-41): AC-125, AC-126, AC-129, AC-133, AC-134.
@MainActor
final class AccountSettingsTests: XCTestCase {

    private func signedIn(_ backend: AccountBackend) -> (AccountHarness, AccountSettingsModel) {
        let h = AccountHarness(transport: backend, refreshToken: "r1", accessToken: "a1", status: .signedIn(riderId: "rider-1"))
        h.memory.remember(riderId: "rider-1", email: "anna@example.com")
        return (h, AccountSettingsModel(actions: h.actions))
    }

    /// AC-125.
    func testTheEmailIsShown() {
        let (_, model) = signedIn(AccountBackend())
        XCTAssertEqual(model.email, "anna@example.com")
    }

    /// AC-126.
    func testChangingThePasswordKeepsThePhoneSignedIn() async {
        let backend = AccountBackend()
        let (h, model) = signedIn(backend)
        model.currentPassword = "the old password"
        model.newPassword = "the new password"

        await model.changePassword()

        XCTAssertTrue(model.passwordChanged)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(h.state.status, .signedIn(riderId: "rider-1"))
        XCTAssertEqual(try h.tokenStore.load(), "r1")
        let sent = await backend.sent
        XCTAssertEqual(sent.first?.path, "/api/v1/account/password")
        XCTAssertEqual(sent.first?.authorization, "Bearer a1")
        XCTAssertEqual(sent.first?.body, ["currentPassword": "the old password", "newPassword": "the new password"])
    }

    func testAWrongCurrentPasswordShowsTheMessage() async {
        let (_, model) = signedIn(AccountBackend(passwordStatus: 401))
        model.currentPassword = "not my password"
        model.newPassword = "the new password"

        await model.changePassword()

        XCTAssertEqual(model.errorMessage, "Password is incorrect")
        XCTAssertFalse(model.passwordChanged)
    }

    func testAShortNewPasswordIsNotSent() async {
        let backend = AccountBackend()
        let (_, model) = signedIn(backend)
        model.currentPassword = "the old password"
        model.newPassword = "short"

        await model.changePassword()

        let sent = await backend.sent
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(model.errorMessage, "Password must be at least 10 characters")
    }

    /// AC-133, AC-129.
    func testDeletionAsksForThePasswordThenErasesEverything() async throws {
        let backend = AccountBackend()
        let (h, model) = signedIn(backend)
        try await h.seedLocalData()

        model.requestDelete()
        XCTAssertTrue(model.isDeletePromptPresented)
        await model.deleteAccount()
        var sent = await backend.sent
        XCTAssertTrue(sent.isEmpty, "nothing is sent without the password")

        model.deletePassword = "my password"
        await model.deleteAccount()

        sent = await backend.sent
        XCTAssertEqual(sent.first?.path, "/api/v1/account/delete")
        XCTAssertEqual(sent.first?.body, ["password": "my password"])
        let rides = try await h.rideStore.fetchAll()
        let routes = try await h.routeStore.fetchAll()
        XCTAssertTrue(rides.isEmpty)
        XCTAssertTrue(routes.isEmpty)
        XCTAssertNil(try h.tokenStore.load())
        XCTAssertEqual(h.state.status, .signedOut)
    }

    func testAFailedDeletionKeepsEverything() async throws {
        let (h, model) = signedIn(AccountBackend(deleteStatus: 401))
        try await h.seedLocalData()
        model.requestDelete()
        model.deletePassword = "wrong password"

        await model.deleteAccount()

        XCTAssertEqual(model.errorMessage, "Password is incorrect")
        let rides = try await h.rideStore.fetchAll()
        XCTAssertEqual(rides.count, 1)
        XCTAssertEqual(h.state.status, .signedIn(riderId: "rider-1"))
    }

    /// AC-134.
    func testDeletionIsNotOfferedDuringARide() {
        let (h, model) = signedIn(AccountBackend())
        XCTAssertTrue(model.canDeleteAccount)

        XCTAssertTrue(h.rideCoordinator.beginPreparingRide())

        XCTAssertFalse(model.canDeleteAccount)
        model.requestDelete()
        XCTAssertFalse(model.isDeletePromptPresented)
    }

    /// AC-127 through the model: the warning names the rides.
    func testTheSignOutWarningNamesTheRides() async throws {
        let (h, model) = signedIn(AccountBackend())
        try await h.seedLocalData()

        await model.prepareSignOut()

        XCTAssertEqual(model.signOutWarning,
                       "Signing out deletes your routes and rides from this phone. 1 ride isn't uploaded yet and will be lost.")
    }
}

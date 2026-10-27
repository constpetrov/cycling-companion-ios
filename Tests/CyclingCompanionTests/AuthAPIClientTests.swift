import XCTest

@testable import CyclingCompanion

/// Answers every request with one scripted status and body, and records what it was sent.
actor ScriptedAuthTransport: HTTPTransport {
    struct Sent: Sendable {
        let path: String
        let body: [String: String]
        let demoKey: String?
        let authorization: String?
        let timeout: TimeInterval
    }

    private var status: Int
    private var body: String
    private var failure: URLError?
    private(set) var sent: [Sent] = []

    init(status: Int = 200, body: String = "", failure: URLError? = nil) {
        self.status = status
        self.body = body
        self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let decoded = (try? JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())) ?? [:]
        sent.append(Sent(path: request.url!.path, body: decoded,
                         demoKey: request.value(forHTTPHeaderField: "X-CC-Demo-Key"),
                         authorization: request.value(forHTTPHeaderField: "Authorization"),
                         timeout: request.timeoutInterval))
        if let failure { throw failure }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Milestone 10 task-4.2 (RULE-15, RULE-32).
final class AuthAPIClientTests: XCTestCase {

    private static let tokens = #"{"accessToken":"a1","refreshToken":"r1","riderId":"rider-1","accessTokenExpiresIn":3600}"#

    private func client(_ transport: HTTPTransport) -> AuthAPIClient {
        AuthAPIClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport, demoAccessToken: "demo")
    }

    func testEachPublicCallPostsItsPathBodyAndDemoKey() async throws {
        let transport = ScriptedAuthTransport(body: Self.tokens)
        let api = client(transport)

        _ = try await api.signUp(email: "a@example.com", password: "pw-123456789", inviteCode: "ABCDE-FGHJK")
        _ = try await api.signIn(email: "a@example.com", password: "pw-123456789")
        _ = try await api.refresh(refreshToken: "r0")
        _ = try await api.reset(email: "a@example.com", code: "KLMNP-QRSTU", newPassword: "new-password")

        let sent = await transport.sent
        XCTAssertEqual(sent.map(\.path), ["/api/v1/auth/sign-up", "/api/v1/auth/sign-in", "/api/v1/auth/refresh",
                                          "/api/v1/auth/reset"])
        XCTAssertEqual(sent[0].body, ["email": "a@example.com", "password": "pw-123456789", "inviteCode": "ABCDE-FGHJK"])
        XCTAssertEqual(sent[2].body, ["refreshToken": "r0"])
        XCTAssertEqual(sent[3].body, ["email": "a@example.com", "code": "KLMNP-QRSTU", "newPassword": "new-password"])
        XCTAssertTrue(sent.allSatisfy { $0.demoKey == "demo" && $0.authorization == nil })
    }

    func testTokensAreDecoded() async throws {
        let tokens = try await client(ScriptedAuthTransport(body: Self.tokens)).signIn(email: "a@example.com",
                                                                                       password: "pw-123456789")

        XCTAssertEqual(tokens, TokenResponse(accessToken: "a1", refreshToken: "r1", riderId: "rider-1",
                                             accessTokenExpiresIn: 3600))
    }

    func testABackendRefusalCarriesItsCodeAndMessage() async {
        let transport = ScriptedAuthTransport(
            status: 401, body: #"{"error":"BAD_CREDENTIALS","message":"Email or password is incorrect"}"#)

        do {
            _ = try await client(transport).signIn(email: "a@example.com", password: "wrong-password")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error, .refused(code: "BAD_CREDENTIALS", message: "Email or password is incorrect", status: 401))
            XCTAssertEqual(error.message, "Email or password is incorrect")
            XCTAssertFalse(error.endsSession)
        }
    }

    func testSessionEndingCodes() {
        XCTAssertTrue(AuthAPIError.refused(code: "SESSION_INVALID", message: "m", status: 401).endsSession)
        XCTAssertTrue(AuthAPIError.refused(code: "ACCOUNT_DISABLED", message: "m", status: 403).endsSession)
        XCTAssertFalse(AuthAPIError.unavailable.endsSession)
    }

    func testANonJsonServerErrorIsUnavailable() async {
        do {
            _ = try await client(ScriptedAuthTransport(status: 502, body: "<html>Bad gateway</html>")).refresh(refreshToken: "r")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testANetworkFailureIsUnavailable() async {
        do {
            _ = try await client(ScriptedAuthTransport(failure: URLError(.notConnectedToInternet))).refresh(refreshToken: "r")
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testSignOutUsesAShortTimeout() async throws {
        let transport = ScriptedAuthTransport(status: 204)

        try await client(transport).signOut(refreshToken: "r1")

        let sent = await transport.sent
        XCTAssertEqual(sent.first?.path, "/api/v1/auth/sign-out")
        XCTAssertEqual(sent.first?.timeout, AuthAPIClient.signOutTimeoutSeconds)
    }

    func testAccountRequestsAreBuiltWithoutABearerToken() {
        let api = client(ScriptedAuthTransport())

        let change = api.changePasswordRequest(currentPassword: "old-password", newPassword: "new-password")
        let delete = api.deleteAccountRequest(password: "my-password")

        XCTAssertEqual(change.url?.path, "/api/v1/account/password")
        XCTAssertEqual(delete.url?.path, "/api/v1/account/delete")
        XCTAssertNil(change.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(change.httpMethod, "POST")
    }
}

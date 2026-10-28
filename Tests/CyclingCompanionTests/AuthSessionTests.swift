import XCTest

@testable import CyclingCompanion

/// A backend whose API answers 200 only to the current access token, and whose refresh endpoint
/// hands out the next one (or a scripted refusal or failure). Counts refreshes.
actor FakeTokenBackend: HTTPTransport {
    enum RefreshAnswer: Sendable {
        case tokens
        case refused(status: Int, code: String, message: String)
        case offline
    }

    private(set) var currentAccessToken: String
    private var refreshAnswer: RefreshAnswer
    private let refreshDelayNanoseconds: UInt64
    private var apiAlways401 = false
    private(set) var refreshCalls = 0
    private(set) var apiCalls = 0
    private var issued = 0

    init(currentAccessToken: String = "valid", refreshAnswer: RefreshAnswer = .tokens, refreshDelayNanoseconds: UInt64 = 0) {
        self.currentAccessToken = currentAccessToken
        self.refreshAnswer = refreshAnswer
        self.refreshDelayNanoseconds = refreshDelayNanoseconds
    }

    func setApiAlways401() {
        apiAlways401 = true
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        if url.path.hasSuffix("/auth/refresh") {
            refreshCalls += 1
            if refreshDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
            }
            switch refreshAnswer {
            case .tokens:
                issued += 1
                currentAccessToken = "access-\(issued)"
                let body = #"{"accessToken":"\#(currentAccessToken)","refreshToken":"refresh-\#(issued)","riderId":"rider-1","accessTokenExpiresIn":3600}"#
                return (Data(body.utf8), Self.response(url, 200))
            case let .refused(status, code, message):
                return (Data(#"{"error":"\#(code)","message":"\#(message)"}"#.utf8), Self.response(url, status))
            case .offline:
                throw URLError(.notConnectedToInternet)
            }
        }
        apiCalls += 1
        let ok = !apiAlways401 && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(currentAccessToken)"
        return (ok ? Data(#"{"ok":true}"#.utf8) : Data(), Self.response(url, ok ? 200 : 401))
    }

    /// A 401 here is a token rejection, so it carries the Bearer challenge like Spring's.
    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                        headerFields: status == 401 ? ["WWW-Authenticate": #"Bearer error="invalid_token""#] : nil)!
    }
}

/// Milestone 10 task-4.3 (RULE-32 to RULE-34): AC-117 to AC-122.
final class AuthSessionTests: XCTestCase {

    private let apiRequest = URLRequest(url: URL(string: "https://backend.example.com/api/v1/routes/x/corridor")!)

    private func session(_ backend: FakeTokenBackend, accessToken: String?, store: TokenStore = InMemoryTokenStore(token: "refresh-0"))
        -> AuthSession
    {
        AuthSession(api: AuthAPIClient(baseURL: URL(string: "https://backend.example.com")!, transport: backend,
                                       demoAccessToken: "demo"),
                    tokenStore: store, transport: backend, accessToken: accessToken)
    }

    func testAValidTokenIsSentWithoutRefreshing() async throws {
        let backend = FakeTokenBackend(currentAccessToken: "valid")

        let (_, response) = try await session(backend, accessToken: "valid").send(apiRequest)

        XCTAssertEqual(response.statusCode, 200)
        let refreshes = await backend.refreshCalls
        XCTAssertEqual(refreshes, 0)
    }

    /// AC-117.
    func testA401RefreshesOnceAndRepeatsTheRequestOnce() async throws {
        let backend = FakeTokenBackend(currentAccessToken: "valid")
        let store = InMemoryTokenStore(token: "refresh-0")

        let (_, response) = try await session(backend, accessToken: "expired", store: store).send(apiRequest)

        XCTAssertEqual(response.statusCode, 200)
        let refreshes = await backend.refreshCalls
        let apiCalls = await backend.apiCalls
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(apiCalls, 2)
        XCTAssertEqual(try store.load(), "refresh-1", "the rotated refresh token is kept")
    }

    /// AC-118.
    func testASecondUnauthorizedAnswerEndsTheSession() async {
        let backend = FakeTokenBackend()
        await backend.setApiAlways401()
        let store = InMemoryTokenStore(token: "refresh-0")
        let session = session(backend, accessToken: "expired", store: store)

        do {
            _ = try await session.send(apiRequest)
            XCTFail("expected the session to end")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .sessionEnded(.expired))
        }
        let apiCalls = await backend.apiCalls
        XCTAssertEqual(apiCalls, 2, "the request is repeated once, not again")
        XCTAssertNil(try store.load())
    }

    /// AC-119.
    func testConcurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let backend = FakeTokenBackend(currentAccessToken: "valid", refreshDelayNanoseconds: 50_000_000)
        let session = session(backend, accessToken: "expired")

        let request = apiRequest
        async let a = session.send(request)
        async let b = session.send(request)
        async let c = session.send(request)
        let statuses = try await [a.1.statusCode, b.1.statusCode, c.1.statusCode]

        XCTAssertEqual(statuses, [200, 200, 200])
        let refreshes = await backend.refreshCalls
        XCTAssertEqual(refreshes, 1)
    }

    /// AC-120.
    func testARefusedRefreshEndsTheSession() async {
        let backend = FakeTokenBackend(refreshAnswer: .refused(status: 401, code: "SESSION_INVALID", message: "Your session has ended"))
        let store = InMemoryTokenStore(token: "refresh-0")
        let session = session(backend, accessToken: "expired", store: store)
        var events = session.events.makeAsyncIterator()

        do {
            _ = try await session.send(apiRequest)
            XCTFail("expected the session to end")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .sessionEnded(.expired))
        }
        XCTAssertNil(try store.load())
        let event = await events.next()
        XCTAssertEqual(event, .ended(.expired))
    }

    /// AC-121.
    func testADisabledAccountEndsTheSessionWithItsMessage() async {
        let backend = FakeTokenBackend(refreshAnswer: .refused(status: 403, code: "ACCOUNT_DISABLED", message: "This account is disabled"))
        let session = session(backend, accessToken: "expired")
        var events = session.events.makeAsyncIterator()

        do {
            _ = try await session.send(apiRequest)
            XCTFail("expected the session to end")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .sessionEnded(.disabled(message: "This account is disabled")))
        }
        let event = await events.next()
        XCTAssertEqual(event, .ended(.disabled(message: "This account is disabled")))
    }

    /// AC-122.
    func testAnOfflineRefreshKeepsTheSession() async {
        let backend = FakeTokenBackend(refreshAnswer: .offline)
        let store = InMemoryTokenStore(token: "refresh-0")
        let session = session(backend, accessToken: "expired", store: store)

        do {
            _ = try await session.send(apiRequest)
            XCTFail("expected a transient failure")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .unavailable)
        }
        XCTAssertEqual(try store.load(), "refresh-0")
        let stored = await session.hasStoredSession()
        XCTAssertTrue(stored)
    }

    /// AC-122, RULE-34: a server error while refreshing is transient too.
    func testAServerErrorWhileRefreshingKeepsTheSession() async {
        let backend = FakeTokenBackend(refreshAnswer: .refused(status: 503, code: "UNAVAILABLE", message: "down"))
        let store = InMemoryTokenStore(token: "refresh-0")

        do {
            _ = try await session(backend, accessToken: "expired", store: store).send(apiRequest)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .unavailable)
        }
        XCTAssertEqual(try store.load(), "refresh-0")
    }

    /// RULE-34: a locked Keychain is not signed out.
    func testALockedKeychainIsTransient() async {
        let backend = FakeTokenBackend()
        let session = session(backend, accessToken: nil, store: LockedTokenStore())

        do {
            _ = try await session.send(apiRequest)
            XCTFail("expected a transient failure")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .unavailable)
        }
        let stored = await session.hasStoredSession()
        XCTAssertTrue(stored)
    }

    func testWithoutAStoredTokenTheSessionHasEnded() async {
        let backend = FakeTokenBackend()
        let session = session(backend, accessToken: nil, store: InMemoryTokenStore())

        do {
            _ = try await session.send(apiRequest)
            XCTFail("expected no session")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .sessionEnded(.expired))
        }
        let refreshes = await backend.refreshCalls
        XCTAssertEqual(refreshes, 0)
    }

    func testAdoptingTokensStoresTheRefreshTokenAndAnnouncesTheRider() async throws {
        let backend = FakeTokenBackend(currentAccessToken: "a1")
        let store = InMemoryTokenStore()
        let session = session(backend, accessToken: nil, store: store)
        var events = session.events.makeAsyncIterator()

        try await session.adopt(TokenResponse(accessToken: "a1", refreshToken: "r1", riderId: "rider-7", accessTokenExpiresIn: 3600))

        XCTAssertEqual(try store.load(), "r1")
        let event = await events.next()
        XCTAssertEqual(event, .signedIn(riderId: "rider-7"))
        let (_, response) = try await session.send(apiRequest)
        XCTAssertEqual(response.statusCode, 200)
    }

    /// A 401 without the Bearer challenge (e.g. PASSWORD_INCORRECT) is an answer, not an expired token.
    func testA401WithoutTheBearerChallengeIsReturnedAsIs() async throws {
        let recorder = ScriptedAuthTransport(status: 401, body: #"{"error":"PASSWORD_INCORRECT","message":"Password is incorrect"}"#)
        let session = AuthSession(api: AuthAPIClient(baseURL: TestAuth.baseURL, transport: recorder),
                                  tokenStore: InMemoryTokenStore(token: "r"), transport: recorder, accessToken: "a")

        let (_, response) = try await session.send(apiRequest)

        XCTAssertEqual(response.statusCode, 401)
        let sent = await recorder.sent
        XCTAssertEqual(sent.map(\.path), ["/api/v1/routes/x/corridor"], "no refresh, no retry")
        let stored = await session.hasStoredSession()
        XCTAssertTrue(stored)
    }

    /// Milestone 10 review: a refresh that returns after sign-out doesn't bring the session back.
    func testARefreshThatReturnsAfterSignOutIsDiscarded() async throws {
        let backend = FakeTokenBackend(currentAccessToken: "valid", refreshDelayNanoseconds: 200_000_000)
        let store = InMemoryTokenStore(token: "refresh-0")
        let session = session(backend, accessToken: nil, store: store)
        let request = apiRequest

        let sending = Task { try await session.send(request) }
        while await backend.refreshCalls == 0 { await Task.yield() }
        await session.clear()

        do {
            _ = try await sending.value
            XCTFail("expected the request to fail")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .sessionChanged)
        }
        XCTAssertNil(try store.load(), "the rotated token must not be saved after sign-out")
        let stored = await session.hasStoredSession()
        XCTAssertFalse(stored)
    }

    /// Milestone 10 review: another rider signing in during a refresh keeps their own session, and
    /// the first rider's request is never sent with it.
    func testARefreshThatReturnsAfterAnotherRiderSignedInIsDiscarded() async throws {
        let backend = FakeTokenBackend(currentAccessToken: "valid", refreshDelayNanoseconds: 200_000_000)
        let store = InMemoryTokenStore(token: "refresh-0")
        let session = session(backend, accessToken: nil, store: store)
        let request = apiRequest

        let sending = Task { try await session.send(request) }
        while await backend.refreshCalls == 0 { await Task.yield() }
        try await session.adopt(TokenResponse(accessToken: "b-access", refreshToken: "b-refresh", riderId: "rider-b",
                                              accessTokenExpiresIn: 3600))

        do {
            _ = try await sending.value
            XCTFail("expected the request to fail")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .sessionChanged)
        }
        XCTAssertEqual(try store.load(), "b-refresh")
        let apiCalls = await backend.apiCalls
        XCTAssertEqual(apiCalls, 0, "the first rider's request never went out with rider B's token")
    }

    func testRequestsCarryTheDemoKey() async throws {
        let recorder = ScriptedAuthTransport(status: 200, body: "{}")
        let session = AuthSession(api: AuthAPIClient(baseURL: URL(string: "https://backend.example.com")!, transport: recorder,
                                                     demoAccessToken: "demo"),
                                  tokenStore: InMemoryTokenStore(token: "r"), transport: recorder, accessToken: "a")

        _ = try await session.send(apiRequest)

        let sent = await recorder.sent
        XCTAssertEqual(sent.first?.demoKey, "demo")
        XCTAssertEqual(sent.first?.authorization, "Bearer a")
    }
}

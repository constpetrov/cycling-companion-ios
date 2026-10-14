import XCTest

@testable import CyclingCompanion

private actor CountingTransport: HTTPTransport {
    private var callCount = 0

    func callCountSoFar() -> Int { callCount }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let body = #"{"token":"stub-jwt-value","riderId":"11111111-1111-1111-1111-111111111111"}"#
            .data(using: .utf8)!
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// task-2.3 validation (RULE-11 in spec/rules.md, AC-4/AC-5).
final class LazySignInTests: XCTestCase {

    func testFirstCallSignsIn() async throws {
        let transport = CountingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)

        try await lazySignIn.ensureSignedIn()

        let callCount = await transport.callCountSoFar()
        XCTAssertEqual(callCount, 1)
    }

    func testSecondCallDoesNotSignInAgain() async throws {
        let transport = CountingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)

        try await lazySignIn.ensureSignedIn()
        try await lazySignIn.ensureSignedIn()

        let callCount = await transport.callCountSoFar()
        XCTAssertEqual(callCount, 1)
    }

    /// task-1.4 validation (Risk Hotspot 5 in spec/review.md): this milestone adds
    /// `AdvisorClient` as a second caller of `LazySignIn.ensureSignedIn()` alongside the
    /// existing `CorridorImportCoordinator`, the first time two call sites can plausibly race
    /// — e.g. a ride starting immediately after import, before sign-in has settled. Confirms
    /// the actor's isolation makes concurrent calls safe rather than assuming it from the
    /// single-caller tests above.
    func testConcurrentEnsureSignedInCallsResultInExactlyOneSignIn() async throws {
        let transport = CountingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)

        async let first: Void = lazySignIn.ensureSignedIn()
        async let second: Void = lazySignIn.ensureSignedIn()
        _ = try await (first, second)

        let callCount = await transport.callCountSoFar()
        XCTAssertEqual(callCount, 1, "two concurrent callers must still only trigger one sign-in network call")
    }

    func testAuthorizeSucceedsAfterEnsureSignedIn() async throws {
        let transport = CountingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let lazySignIn = LazySignIn(authClient: authClient)

        try await lazySignIn.ensureSignedIn()

        let request = URLRequest(url: URL(string: "https://backend.example.com/api/v1/routes")!)
        let authorized = try await authClient.authorize(request)
        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer stub-jwt-value")
    }
}

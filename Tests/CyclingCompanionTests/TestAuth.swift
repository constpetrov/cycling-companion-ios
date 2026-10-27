import Foundation

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

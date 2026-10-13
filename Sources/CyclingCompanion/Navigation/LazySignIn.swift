import Foundation

/// Ensures `AuthStubClient.signIn` is called exactly once, lazily, before the first Route API
/// call (RULE-11 in spec/rules.md, AC-4/AC-5) — every caller awaits this before making any
/// Route API request through the shared `AuthStubClient` instance; a no-op after the first
/// successful call, so a second (or later) Route API call never signs in again.
actor LazySignIn {
    private let authClient: AuthStubClient
    private let placeholderIdentity: String
    private var hasSignedIn = false

    init(authClient: AuthStubClient, placeholderIdentity: String = "rider") {
        self.authClient = authClient
        self.placeholderIdentity = placeholderIdentity
    }

    func ensureSignedIn() async throws {
        guard !hasSignedIn else { return }
        try await authClient.signIn(placeholderIdentity: placeholderIdentity)
        hasSignedIn = true
    }
}

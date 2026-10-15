import Foundation

/// Ensures `AuthStubClient.signIn` is called exactly once, lazily, before the first Route API
/// call (RULE-11 in spec/rules.md, AC-4/AC-5) — every caller awaits this before making any
/// Route API request through the shared `AuthStubClient` instance; a no-op after the first
/// successful call, so a second (or later) Route API call never signs in again.
///
/// Concurrent callers share a single in-flight attempt (RULE-19/Risk Hotspot 5 in
/// spec/review.md): without `inFlightSignIn`, two callers that both arrive before the first
/// completes would both pass the `hasSignedIn` guard (an actor only serializes between
/// suspension points, and `authClient.signIn` awaits one) and both call `signIn`, exactly the
/// double sign-in this type exists to prevent. A second caller instead awaits the first
/// caller's own `Task`, so only one `signIn` call ever happens regardless of overlap.
actor LazySignIn {
    private static let log = Log.logger(category: "Auth")

    private let authClient: AuthStubClient
    private let placeholderIdentity: String
    private var hasSignedIn = false
    private var inFlightSignIn: Task<Void, Error>?

    init(authClient: AuthStubClient, placeholderIdentity: String = "rider") {
        self.authClient = authClient
        self.placeholderIdentity = placeholderIdentity
    }

    func ensureSignedIn() async throws {
        guard !hasSignedIn else { return }
        if let inFlightSignIn {
            // Piggybacking on someone else's attempt: never cancel the shared task just
            // because this particular await is cancelled — another caller (maybe the owner
            // below) may still need it to finish.
            try await inFlightSignIn.value
            return
        }
        let task = Task<Void, Error> { [authClient, placeholderIdentity] in
            _ = try await authClient.signIn(placeholderIdentity: placeholderIdentity)
        }
        inFlightSignIn = task
        defer { inFlightSignIn = nil }
        // `Task.value` does not observe this call's own cancellation — a `Task { }` is
        // unstructured, so cancelling whatever called `ensureSignedIn()` would otherwise never
        // reach the underlying `signIn` network call, leaving it to run forever. Explicitly
        // cancelling the owned task on cancellation is what actually propagates it.
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            Self.log.error("Sign-in failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        hasSignedIn = true
        Self.log.info("Signed in as \(self.placeholderIdentity, privacy: .public)")
    }
}

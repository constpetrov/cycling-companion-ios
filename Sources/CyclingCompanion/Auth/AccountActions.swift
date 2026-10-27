import Foundation

/// The account operations behind the sign-in screens and Settings (milestone 10, RULE-39 to RULE-41):
/// they call the backend, then update the session, the remembered rider and the local data together.
@MainActor
final class AccountActions {
    private static let log = Log.logger(category: "Auth")

    private let api: AuthAPIClient
    private let session: AuthSession
    private let sessionState: SessionState
    private let accountMemory: AccountMemory

    init(api: AuthAPIClient, session: AuthSession, sessionState: SessionState, accountMemory: AccountMemory) {
        self.api = api
        self.session = session
        self.sessionState = sessionState
        self.accountMemory = accountMemory
    }

    func signIn(email: String, password: String) async throws(AuthAPIError) {
        try await start(api.signIn(email: email, password: password), email: email)
    }

    func signUp(email: String, password: String, inviteCode: String) async throws(AuthAPIError) {
        try await start(api.signUp(email: email, password: password, inviteCode: inviteCode), email: email)
    }

    func reset(email: String, code: String, newPassword: String) async throws(AuthAPIError) {
        try await start(api.reset(email: email, code: code, newPassword: newPassword), email: email)
    }

    /// Keeps the tokens and remembers who signed in. The email is stored as typed but normalized
    /// like the backend (trimmed, lowercased), so Settings shows what the account is.
    private func start(_ tokens: TokenResponse, email: String) async throws(AuthAPIError) {
        do {
            try await session.adopt(tokens)
        } catch {
            // Only a Keychain that can't be written gets here; the rider can try again.
            Self.log.error("Couldn't store the session: \(String(describing: error), privacy: .public)")
            throw .unavailable
        }
        accountMemory.remember(riderId: tokens.riderId, email: Self.normalized(email))
    }

    static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

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
    private let eraser: LocalDataEraser
    private let pendingUploadQueue: PendingRideUploadQueue
    private let rideCoordinator: RideCoordinator

    init(
        api: AuthAPIClient, session: AuthSession, sessionState: SessionState, accountMemory: AccountMemory,
        eraser: LocalDataEraser, pendingUploadQueue: PendingRideUploadQueue, rideCoordinator: RideCoordinator
    ) {
        self.api = api
        self.session = session
        self.sessionState = sessionState
        self.accountMemory = accountMemory
        self.eraser = eraser
        self.pendingUploadQueue = pendingUploadQueue
        self.rideCoordinator = rideCoordinator
    }

    /// RULE-39: rides that would be lost — queued uploads, plus a ride in progress.
    func unuploadedRideCount() async -> Int {
        let queued = (try? await pendingUploadQueue.fetchAllOldestFirst().count) ?? 0
        return queued + (rideCoordinator.activeRide == nil ? 0 : 1)
    }

    /// RA-13, RULE-39: tells the backend once (short timeout, no retry, outcome ignored), then
    /// erases the local data and the session whatever happened.
    func signOut() async {
        if let refreshToken = await session.storedRefreshToken() {
            try? await api.signOut(refreshToken: refreshToken)
        }
        await eraser.eraseAll()
        accountMemory.forget()
        sessionState.signedOut()
        Self.log.info("Signed out; local data erased")
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

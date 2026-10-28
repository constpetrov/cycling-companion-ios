import Foundation

/// Why a session ended (RULE-34 in milestone 10's rules.md).
enum SessionEndReason: Equatable, Sendable {
    /// The refresh token is expired, revoked or unknown, or a refreshed request still got 401.
    case expired
    /// The admin disabled the account; `message` is the backend's text.
    case disabled(message: String)
}

enum AuthSessionError: Error, Equatable {
    /// No session: nobody signed in, or the session just ended (`reason`).
    case sessionEnded(SessionEndReason)
    /// The rider signed out or another rider signed in while this request was under way; it is
    /// never re-sent with the new session's token.
    case sessionChanged
    /// The session is fine but couldn't be renewed right now (offline, 5xx, Keychain locked).
    case unavailable
}

/// Holds the signed-in rider's tokens and sends every authenticated request (RULE-32 to RULE-34 in
/// milestone 10's rules.md): the access token only in memory, the refresh token in a `TokenStore`.
///
/// `send` adds the bearer token and the demo key. A 401 triggers one refresh, shared by every
/// request that hits 401 meanwhile, and one repeat; a second 401 ends the session. A refresh the
/// backend refuses ends the session; offline, a 5xx or a locked Keychain don't (they fail the
/// request like any offline request).
actor AuthSession {
    enum Event: Equatable, Sendable {
        case signedIn(riderId: String)
        case ended(SessionEndReason)
    }

    private static let log = Log.logger(category: "Auth")

    private let api: AuthAPIClient
    private let tokenStore: TokenStore
    private let transport: HTTPTransport
    private var accessToken: String?
    private var inFlightRefresh: Task<Void, Error>?
    /// Bumped by `adopt` and `clear`. Work that suspended (a refresh, a request) checks it afterwards,
    /// so a late answer for an old session can't revive it or leak into the new one (actor
    /// reentrancy; milestone 10 review).
    private var generation = 0
    private let eventsContinuation: AsyncStream<Event>.Continuation

    /// Sign-ins and session ends, for `SessionState`.
    nonisolated let events: AsyncStream<Event>

    init(api: AuthAPIClient, tokenStore: TokenStore, transport: HTTPTransport, accessToken: String? = nil) {
        self.api = api
        self.tokenStore = tokenStore
        self.transport = transport
        self.accessToken = accessToken
        (events, eventsContinuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Whether a refresh token is stored. A locked Keychain counts as yes: the token is still there.
    func hasStoredSession() -> Bool {
        tokenStore.hasStoredToken
    }

    /// After sign-in, sign-up or reset: keeps the new tokens and announces the rider.
    func adopt(_ tokens: TokenResponse) throws {
        try tokenStore.save(tokens.refreshToken)
        generation += 1
        accessToken = tokens.accessToken
        eventsContinuation.yield(.signedIn(riderId: tokens.riderId))
    }

    /// Forgets both tokens (sign-out, account deletion); the caller tells the backend if it can.
    func clear() {
        generation += 1
        accessToken = nil
        try? tokenStore.delete()
    }

    /// The stored refresh token, for sign-out.
    func storedRefreshToken() -> String? {
        try? tokenStore.load()
    }

    /// Sends an authenticated request; see the type's documentation for the 401 handling.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let started = generation
        if accessToken == nil {
            try await refresh(replacing: nil)
        }
        guard generation == started else { throw AuthSessionError.sessionChanged }
        guard let used = accessToken else { throw AuthSessionError.sessionEnded(.expired) }
        let (data, response) = try await perform(request, token: used)
        guard Self.rejectsToken(response) else { return (data, response) }

        try await refresh(replacing: used)
        // Another rider's token must never carry this rider's request.
        guard generation == started else { throw AuthSessionError.sessionChanged }
        guard let renewed = accessToken else { throw AuthSessionError.sessionEnded(.expired) }
        let (retryData, retryResponse) = try await perform(request, token: renewed)
        guard Self.rejectsToken(retryResponse) else { return (retryData, retryResponse) }
        Self.log.notice("A refreshed request still got 401 — ending the session")
        end(.expired)
        throw AuthSessionError.sessionEnded(.expired)
    }

    /// A 401 about the access token carries `WWW-Authenticate: Bearer …` (Spring's resource server and
    /// the rider-exists check). Other 401s are answers, not token problems: a wrong current password
    /// is 401 `PASSWORD_INCORRECT` and must not end the session.
    static func rejectsToken(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 401 else { return false }
        return response.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased().hasPrefix("bearer") ?? false
    }

    private func perform(_ request: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
        var authorized = api.withDemoKey(request)
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: authorized)
        guard let http = response as? HTTPURLResponse else { throw AuthSessionError.unavailable }
        return (data, http)
    }

    /// RULE-33: one refresh at a time. A caller whose token was already replaced by someone else's
    /// refresh just uses the new one; everyone else waits for the single in-flight refresh. The
    /// shared task isn't cancelled with one waiting caller: it is short, and cancelling it could
    /// lose a token the backend already rotated.
    private func refresh(replacing used: String?) async throws {
        if let current = accessToken, current != used {
            return
        }
        if let inFlightRefresh {
            try await inFlightRefresh.value
            return
        }
        let task = Task { try await performRefresh() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        let started = generation
        let stored: String?
        do {
            stored = try tokenStore.load()
        } catch {
            // RULE-34: a locked Keychain is not a signed-out rider.
            throw AuthSessionError.unavailable
        }
        guard let stored else {
            throw AuthSessionError.sessionEnded(.expired)
        }
        do {
            let tokens = try await api.refresh(refreshToken: stored)
            // Signed out or switched riders meanwhile: this answer belongs to a session that's gone.
            guard generation == started else { throw AuthSessionError.sessionChanged }
            try? tokenStore.save(tokens.refreshToken)
            accessToken = tokens.accessToken
        } catch let error as AuthSessionError {
            throw error
        } catch let error as AuthAPIError where error.endsSession {
            guard generation == started else { throw AuthSessionError.sessionChanged }
            let reason: SessionEndReason = error.code == AuthAPIError.accountDisabled
                ? .disabled(message: error.message) : .expired
            Self.log.notice("Refresh refused — ending the session")
            end(reason)
            throw AuthSessionError.sessionEnded(reason)
        } catch {
            throw AuthSessionError.unavailable
        }
    }

    private func end(_ reason: SessionEndReason) {
        accessToken = nil
        try? tokenStore.delete()
        eventsContinuation.yield(.ended(reason))
    }
}

import Foundation

/// What sign-up, sign-in, refresh and reset return (milestone 10, RA-5).
struct TokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let riderId: String
    let accessTokenExpiresIn: Int
}

/// Every way an auth call can fail, as the app needs to tell them apart (RULE-15, RULE-34).
enum AuthAPIError: Error, Equatable, Sendable {
    /// The backend answered with `{"error": code, "message": message}`; `message` is shown as is.
    case refused(code: String, message: String, status: Int)
    /// No answer the app can use: no network, a timeout, a 5xx or a body it can't read.
    case unavailable

    static let sessionInvalid = "SESSION_INVALID"
    static let accountDisabled = "ACCOUNT_DISABLED"

    var code: String? {
        if case let .refused(code, _, _) = self { return code }
        return nil
    }

    /// The text to show the rider.
    var message: String {
        switch self {
        case let .refused(_, message, _): message
        case .unavailable: "Can't reach the server. Check your connection and try again."
        }
    }

    /// RULE-34: only these two answers end a session; anything else leaves the rider signed in.
    var endsSession: Bool {
        code == Self.sessionInvalid || code == Self.accountDisabled
    }
}

/// The backend's auth and account endpoints (milestone 10, RULE-15, RULE-32). Public endpoints go
/// straight to the transport; the two authenticated ones are only built and decoded here and sent
/// through `AuthSession.send`, so the bearer token and the 401 retry live in one place.
struct AuthAPIClient: Sendable {
    /// RULE-39: sign-out is best effort and must not hold up the local sign-out.
    static let signOutTimeoutSeconds: TimeInterval = 5

    private let baseURL: URL
    private let transport: HTTPTransport
    private let demoAccessToken: String?

    init(baseURL: URL, transport: HTTPTransport = URLSession.shared, demoAccessToken: String? = nil) {
        self.baseURL = baseURL
        self.transport = transport
        self.demoAccessToken = demoAccessToken
    }

    func signUp(email: String, password: String, inviteCode: String) async throws(AuthAPIError) -> TokenResponse {
        try await tokens("api/v1/auth/sign-up", ["email": email, "password": password, "inviteCode": inviteCode])
    }

    func signIn(email: String, password: String) async throws(AuthAPIError) -> TokenResponse {
        try await tokens("api/v1/auth/sign-in", ["email": email, "password": password])
    }

    func refresh(refreshToken: String) async throws(AuthAPIError) -> TokenResponse {
        try await tokens("api/v1/auth/refresh", ["refreshToken": refreshToken])
    }

    func reset(email: String, code: String, newPassword: String) async throws(AuthAPIError) -> TokenResponse {
        try await tokens("api/v1/auth/reset", ["email": email, "code": code, "newPassword": newPassword])
    }

    /// Sent once with a short timeout; the caller ignores the outcome (RULE-39).
    func signOut(refreshToken: String) async throws(AuthAPIError) {
        var request = post("api/v1/auth/sign-out", ["refreshToken": refreshToken])
        request.timeoutInterval = Self.signOutTimeoutSeconds
        _ = try await perform(request)
    }

    /// Sent through `AuthSession.send`, which adds the bearer token.
    func changePasswordRequest(currentPassword: String, newPassword: String) -> URLRequest {
        post("api/v1/account/password", ["currentPassword": currentPassword, "newPassword": newPassword])
    }

    /// Sent through `AuthSession.send`, which adds the bearer token.
    func deleteAccountRequest(password: String) -> URLRequest {
        post("api/v1/account/delete", ["password": password])
    }

    /// Adds the gateway's demo key (milestone 6); every `/api` request needs it.
    func withDemoKey(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(demoAccessToken, forHTTPHeaderField: "X-CC-Demo-Key")
        return request
    }

    /// Maps a non-2xx answer to `.refused` when it carries the JSON error body, else `.unavailable`.
    static func error(status: Int, data: Data) -> AuthAPIError {
        struct Body: Decodable {
            let error: String
            let message: String
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return .unavailable }
        return .refused(code: body.error, message: body.message, status: status)
    }

    private func tokens(_ path: String, _ body: [String: String]) async throws(AuthAPIError) -> TokenResponse {
        let data = try await perform(post(path, body))
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw .unavailable
        }
        return tokens
    }

    private func post(_ path: String, _ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func perform(_ request: URLRequest) async throws(AuthAPIError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: withDemoKey(request))
        } catch {
            throw .unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw .unavailable }
        guard (200...299).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data)
        }
        return data
    }
}

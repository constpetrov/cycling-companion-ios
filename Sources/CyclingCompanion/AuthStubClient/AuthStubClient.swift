import Foundation

/// Minimal async HTTP transport, injected so tests never need a live network connection
/// (matches the architecture doc's injected-source testing convention; see RouteStore/Clock).
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

struct SignInResponse: Decodable, Sendable {
    let token: String
    let riderId: String
}

enum AuthStubClientError: Error {
    case notSignedIn
    case unexpectedResponse
}

/// Calls the backend's dev-only sign-in endpoint and attaches the issued JWT to subsequent
/// Route API requests (RULE-18/RULE-25 in spec/rules.md, AC-11/AC-13/AC-14 in spec/criteria.md).
actor AuthStubClient {
    private let baseURL: URL
    private let transport: HTTPTransport
    private var token: String?

    init(baseURL: URL, transport: HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.transport = transport
    }

    @discardableResult
    func signIn(placeholderIdentity: String) async throws -> SignInResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/sign-in"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["placeholderIdentity": placeholderIdentity])

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AuthStubClientError.unexpectedResponse
        }

        let decoded = try JSONDecoder().decode(SignInResponse.self, from: data)
        token = decoded.token
        return decoded
    }

    /// Returns a copy of `request` with the stored JWT attached as a Bearer token, per AC-11.
    func authorize(_ request: URLRequest) throws -> URLRequest {
        guard let token else {
            throw AuthStubClientError.notSignedIn
        }
        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return authorized
    }
}

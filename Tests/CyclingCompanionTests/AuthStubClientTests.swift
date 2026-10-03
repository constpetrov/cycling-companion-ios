import XCTest

@testable import CyclingCompanion

private struct StubTransport: HTTPTransport {
    let statusCode: Int
    let body: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// AC-11 in spec/criteria.md: the iOS app includes the auth-stub JWT on Route API calls.
final class AuthStubClientTests: XCTestCase {

    func testAuthorizeAttachesStoredJWTAsBearerHeader() async throws {
        let body = #"{"token":"stub-jwt-value","riderId":"11111111-1111-1111-1111-111111111111"}"#
            .data(using: .utf8)!
        let client = AuthStubClient(
            baseURL: URL(string: "https://backend.example.com")!,
            transport: StubTransport(statusCode: 200, body: body))

        _ = try await client.signIn(placeholderIdentity: "device-test-identity")

        let request = URLRequest(url: URL(string: "https://backend.example.com/api/v1/routes")!)
        let authorized = try await client.authorize(request)

        XCTAssertEqual(authorized.value(forHTTPHeaderField: "Authorization"), "Bearer stub-jwt-value")
    }

    func testAuthorizeThrowsBeforeSignIn() async {
        let client = AuthStubClient(
            baseURL: URL(string: "https://backend.example.com")!,
            transport: StubTransport(statusCode: 200, body: Data()))

        let request = URLRequest(url: URL(string: "https://backend.example.com/api/v1/routes")!)

        do {
            _ = try await client.authorize(request)
            XCTFail("Expected authorize to throw before sign-in")
        } catch is AuthStubClientError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

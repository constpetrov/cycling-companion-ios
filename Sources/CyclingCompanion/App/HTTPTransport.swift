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

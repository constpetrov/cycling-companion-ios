import Foundation

enum CorridorPollingError: Error {
    case unexpectedResponse
}

/// Sends the imported route to the backend, then polls the corridor-status endpoint until it
/// leaves `building` (RULE-6/RULE-25 in spec/rules.md, AC-29/AC-37 in spec/criteria.md). The
/// 10-minute give-up (AC-38/AC-39) lands in task-4.4 — this polls unboundedly for now, which is
/// exactly what AC-37 ("while building for less than 10 minutes, keep polling") requires on
/// its own.
actor CorridorPollingService {
    private let baseURL: URL
    private let authClient: AuthStubClient
    private let transport: HTTPTransport
    private let clock: Clock
    private let pollIntervalSeconds: TimeInterval

    init(
        baseURL: URL, authClient: AuthStubClient, transport: HTTPTransport = URLSession.shared,
        clock: Clock = SystemClock(), pollIntervalSeconds: TimeInterval = 2.0
    ) {
        self.baseURL = baseURL
        self.authClient = authClient
        self.transport = transport
        self.clock = clock
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    func importRoute(_ route: ImportedRoute) async throws -> ImportRouteResponsePayload {
        let payload = ImportRouteRequestPayload(
            hash: route.hash,
            points: route.points.map {
                RoutePointPayload(
                    latitude: $0.latitude, longitude: $0.longitude, elevationMeters: $0.elevationMeters,
                    cumulativeDistanceMeters: $0.cumulativeDistanceMeters)
            },
            totalDistanceMeters: route.totalDistanceMeters,
            totalClimbingMeters: route.totalClimbingMeters)

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/routes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let authorized = try await authClient.authorize(request)

        let (data, response) = try await transport.data(for: authorized)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CorridorPollingError.unexpectedResponse
        }
        return try JSONDecoder().decode(ImportRouteResponsePayload.self, from: data)
    }

    func pollUntilSettled(routeId: String) async throws -> CorridorStatusResponsePayload {
        while true {
            let status = try await fetchStatus(routeId: routeId)
            if status.status != "building" {
                return status
            }
            try await clock.sleep(for: pollIntervalSeconds)
        }
    }

    private func fetchStatus(routeId: String) async throws -> CorridorStatusResponsePayload {
        let request = URLRequest(url: baseURL.appendingPathComponent("api/v1/routes/\(routeId)/corridor"))
        let authorized = try await authClient.authorize(request)

        let (data, response) = try await transport.data(for: authorized)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CorridorPollingError.unexpectedResponse
        }
        return try JSONDecoder().decode(CorridorStatusResponsePayload.self, from: data)
    }
}

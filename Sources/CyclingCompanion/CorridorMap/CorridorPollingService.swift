import Foundation

enum CorridorPollingError: Error, Equatable {
    case unexpectedResponse
    /// AC-38: the route stayed `building` for the full timeout window without settling.
    case timedOut
}

/// Sends the imported route to the backend, then polls the corridor-status endpoint until it
/// leaves `building` (RULE-6/RULE-25 in spec/rules.md, AC-29/AC-37 in spec/criteria.md), giving
/// up after 10 minutes (AC-38/AC-39, RULE-7/RULE-8) — timed off the injected `Clock`, not a raw
/// `Timer`/`Date()`, since the only thing this actor's loop ever does with time is ask the
/// clock to sleep; summing those sleep durations *is* its elapsed-time source. Once
/// `pollUntilSettled` throws `.timedOut`, nothing in this actor resumes polling on its own
/// (AC-39) — a caller must explicitly call `retry` (which re-enqueues a build, task-4.3's
/// endpoint) and then call `pollUntilSettled` again.
actor CorridorPollingService {
    private let baseURL: URL
    private let authClient: AuthStubClient
    private let transport: HTTPTransport
    private let clock: Clock
    private let pollIntervalSeconds: TimeInterval
    private let timeoutSeconds: TimeInterval

    init(
        baseURL: URL, authClient: AuthStubClient, transport: HTTPTransport = URLSession.shared,
        clock: Clock = SystemClock(), pollIntervalSeconds: TimeInterval = 2.0,
        timeoutSeconds: TimeInterval = 600.0
    ) {
        self.baseURL = baseURL
        self.authClient = authClient
        self.transport = transport
        self.clock = clock
        self.pollIntervalSeconds = pollIntervalSeconds
        self.timeoutSeconds = timeoutSeconds
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
        var elapsedSeconds: TimeInterval = 0
        while true {
            let status = try await fetchStatus(routeId: routeId)
            if status.status != "building" {
                return status
            }
            if elapsedSeconds >= timeoutSeconds {
                throw CorridorPollingError.timedOut
            }
            try await clock.sleep(for: pollIntervalSeconds)
            elapsedSeconds += pollIntervalSeconds
        }
    }

    /// AC-40: re-enqueues a fresh build for the same route without re-importing the GPX file.
    func retry(routeId: String) async throws -> ImportRouteResponsePayload {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/routes/\(routeId)/retry"))
        request.httpMethod = "POST"
        let authorized = try await authClient.authorize(request)

        let (data, response) = try await transport.data(for: authorized)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CorridorPollingError.unexpectedResponse
        }
        return try JSONDecoder().decode(ImportRouteResponsePayload.self, from: data)
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

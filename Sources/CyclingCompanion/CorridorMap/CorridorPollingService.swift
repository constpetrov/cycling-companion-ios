import Foundation

enum CorridorPollingError: Error, Equatable {
    case unexpectedResponse
    /// The backend refused the route import with this HTTP status (milestone 7: lets the app tell
    /// a sign-in problem, 401/403, from any other rejection).
    case rejected(statusCode: Int)
}

/// One corridor status check, classified (milestone 8, RULE-18): only a `status` answer may change
/// what the app stores. A transient problem — no connection, a timeout, a 5xx, a sign-in failure —
/// never becomes a failure; the caller keeps what it has and asks again later.
enum CorridorPollResult: Sendable {
    case status(CorridorStatusResponsePayload)
    case transient
    case notFound
}

/// Talks to the backend's route endpoints: import, a single corridor status check, and Retry.
/// Polling cadence lives in `CorridorImportCoordinator` (milestone 8, RULE-18/RULE-19), which owns
/// one poll per route and decides when to ask again.
actor CorridorPollingService {
    private static let log = Log.logger(category: "CorridorImport")

    private let baseURL: URL
    private let session: AuthSession

    /// Every request goes through `session`, which signs it and renews the session (milestone 10).
    init(baseURL: URL, session: AuthSession) {
        self.baseURL = baseURL
        self.session = session
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

        let (data, http) = try await session.send(request)
        guard http.statusCode == 200 else {
            throw CorridorPollingError.rejected(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(ImportRouteResponsePayload.self, from: data)
    }

    /// AC-40: re-enqueues a fresh build for the same route without re-importing the GPX file.
    func retry(routeId: String) async throws -> ImportRouteResponsePayload {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/routes/\(routeId)/retry"))
        request.httpMethod = "POST"

        let (data, http) = try await session.send(request)
        guard http.statusCode == 200 else {
            throw CorridorPollingError.unexpectedResponse
        }
        return try JSONDecoder().decode(ImportRouteResponsePayload.self, from: data)
    }

    /// One corridor status check. Never throws: 404 is `notFound`; a 200 that decodes is `status`;
    /// anything else (no connection, timeout, 5xx, 408/429, an unauthorized request, a body that
    /// doesn't decode) is `transient`.
    func fetchStatus(routeId: String) async -> CorridorPollResult {
        do {
            let request = URLRequest(url: baseURL.appendingPathComponent("api/v1/routes/\(routeId)/corridor"))
            let (data, http) = try await session.send(request)
            if http.statusCode == 404 { return .notFound }
            guard http.statusCode == 200 else {
                Self.log.notice("Corridor status for \(routeId, privacy: .public) answered HTTP \(http.statusCode, privacy: .public)")
                return .transient
            }
            return .status(try JSONDecoder().decode(CorridorStatusResponsePayload.self, from: data))
        } catch {
            Self.log.notice("Corridor status for \(routeId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .transient
        }
    }
}

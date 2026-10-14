import Foundation
import RoutePersistence

struct AdvisorDecisionRequestPayload: Codable {
    let rideId: String
    let routeId: String
    let featureSnapshot: FeatureSnapshotPayload
    let candidates: [CandidateStopPayload]
}

struct FeatureSnapshotPayload: Codable {
    let timestamp: Date
    let speedVsBaseline: Double?
    let workDone: Double?
    let rideSoFarVsLongest: Double?
    let conditions: Double?
    let speedTrend: Double?
    let hrDrift: Double?
    let cadenceDrop: Int?
    let timeSinceLastStopSeconds: Double?
    let remainingEffortMeters: Double?

    init(snapshot: FeatureSnapshot) {
        timestamp = snapshot.timestamp
        speedVsBaseline = snapshot.speedVsBaseline
        workDone = snapshot.workDone
        rideSoFarVsLongest = snapshot.rideSoFarVsLongest
        conditions = snapshot.conditions
        speedTrend = snapshot.speedTrend
        hrDrift = snapshot.hrDrift
        cadenceDrop = snapshot.cadenceDrop
        timeSinceLastStopSeconds = snapshot.timeSinceLastStopSeconds
        remainingEffortMeters = snapshot.remainingEffortMeters
    }
}

struct CandidateStopPayload: Codable {
    let osmId: Int64
    let type: String
    let name: String?
    let detourMeters: Double
    let kmMarkMeters: Double
    let openingHours: String?

    init(poi: PersistedPoiInput) {
        osmId = poi.osmId
        type = poi.type
        name = poi.name
        detourMeters = poi.detourMeters
        kmMarkMeters = poi.kmMarkMeters
        openingHours = poi.openingHours
    }
}

struct AdvisorDecisionResponsePayload: Decodable {
    let suggest: Bool
    let stopId: String?
    let urgency: String?
    let reason: String?
    let message: String?
}

/// Calls the backend's real Advisor endpoint (RULE-2/RULE-13/RULE-14/RULE-19 in
/// spec/rules.md) — shaped like `CorridorPollingService`: injected `HTTPTransport`/`Clock`/
/// `AuthStubClient`, reuses `LazySignIn` for transparent sign-in (no second sign-in path).
/// Returns `nil` (never throws) for every failure case — timeout, network error, non-2xx,
/// unparseable JSON — so `RideSession` has exactly one uniform "fell back" signal to branch
/// on (RULE-14); it never surfaces which failure occurred.
actor AdvisorClient {
    private let baseURL: URL
    private let authClient: AuthStubClient
    private let lazySignIn: LazySignIn
    private let transport: HTTPTransport
    private let clock: Clock
    private let deadlineSeconds: TimeInterval

    init(
        baseURL: URL, authClient: AuthStubClient, lazySignIn: LazySignIn,
        transport: HTTPTransport = URLSession.shared, clock: Clock = SystemClock(),
        deadlineSeconds: TimeInterval = 8.0
    ) {
        self.baseURL = baseURL
        self.authClient = authClient
        self.lazySignIn = lazySignIn
        self.transport = transport
        self.clock = clock
        self.deadlineSeconds = deadlineSeconds
    }

    func requestDecision(
        rideId: String, routeId: String, snapshot: FeatureSnapshot, candidates: [PersistedPoiInput]
    ) async -> AdvisorDecision? {
        await raceWithDeadline(seconds: deadlineSeconds, clock: clock) { [self] in
            try await fetchDecision(rideId: rideId, routeId: routeId, snapshot: snapshot, candidates: candidates)
        }
    }

    private func fetchDecision(
        rideId: String, routeId: String, snapshot: FeatureSnapshot, candidates: [PersistedPoiInput]
    ) async throws -> AdvisorDecision {
        let payload = AdvisorDecisionRequestPayload(
            rideId: rideId, routeId: routeId, featureSnapshot: FeatureSnapshotPayload(snapshot: snapshot),
            candidates: candidates.map(CandidateStopPayload.init))

        try await lazySignIn.ensureSignedIn()

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/advisor/decision"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)
        let authorized = try await authClient.authorize(request)

        let (data, response) = try await transport.data(for: authorized)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AdvisorClientError.unexpectedResponse
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AdvisorDecisionResponsePayload.self, from: data)
        return AdvisorDecision(
            suggest: decoded.suggest, stopId: decoded.stopId, urgency: decoded.urgency, reason: decoded.reason,
            message: decoded.message)
    }
}

enum AdvisorClientError: Error {
    case unexpectedResponse
}

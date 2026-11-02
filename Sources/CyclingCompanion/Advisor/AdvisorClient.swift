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
    /// Milestone 9: absent from backends before it.
    let traceId: String?
}

/// Calls the backend's real Advisor endpoint (RULE-2/RULE-13/RULE-14/RULE-19 in
/// spec/rules.md) — shaped like `CorridorPollingService`: an injected `Clock`, and every request
/// sent through `AuthSession` (milestone 10, RULE-32), which signs it and renews the session.
/// Returns `nil` (never throws) for every failure case — timeout, network error, non-2xx,
/// unparseable JSON — so `RideSession` has exactly one uniform "fell back" signal to branch
/// on (RULE-14); it never surfaces which failure occurred.
actor AdvisorClient {
    private static let log = Log.logger(category: "Advisor")

    private let baseURL: URL
    private let session: AuthSession
    private let clock: Clock
    private let deadlineSeconds: TimeInterval

    // Allow time for backend history retrieval plus inference; observed successful calls
    // take about 19 seconds. Keep a bounded wait before using the local advisor.
    init(
        baseURL: URL, session: AuthSession, clock: Clock = SystemClock(), deadlineSeconds: TimeInterval = 30.0
    ) {
        self.baseURL = baseURL
        self.session = session
        self.clock = clock
        self.deadlineSeconds = deadlineSeconds
    }

    func requestDecision(
        rideId: String, routeId: String, snapshot: FeatureSnapshot, candidates: [PersistedPoiInput]
    ) async -> AdvisorDecision? {
        let started = Date()
        let decision = await raceWithDeadline(seconds: deadlineSeconds, clock: clock) { [self] in
            try await fetchDecision(rideId: rideId, routeId: routeId, snapshot: snapshot, candidates: candidates)
        }
        let elapsedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        if let decision {
            Self.log.info("Remote Advisor decision for ride \(rideId, privacy: .public): suggest=\(decision.suggest, privacy: .public), durationMs=\(elapsedMilliseconds, privacy: .public)")
        } else {
            Self.log.notice(
                "Remote Advisor call for ride \(rideId, privacy: .public) failed or timed out — falling back to LocalAdvisor (durationMs=\(elapsedMilliseconds, privacy: .public))")
        }
        return decision
    }

    private func fetchDecision(
        rideId: String, routeId: String, snapshot: FeatureSnapshot, candidates: [PersistedPoiInput]
    ) async throws -> AdvisorDecision {
        let payload = AdvisorDecisionRequestPayload(
            rideId: rideId, routeId: routeId, featureSnapshot: FeatureSnapshotPayload(snapshot: snapshot),
            candidates: candidates.map(CandidateStopPayload.init))

        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/advisor/decision"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)
        let (data, http) = try await session.send(request)
        guard (200...299).contains(http.statusCode) else {
            Self.log.notice("Advisor HTTP failure for ride \(rideId, privacy: .public): status=\(http.statusCode, privacy: .public)")
            throw AdvisorClientError.unexpectedResponse
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AdvisorDecisionResponsePayload.self, from: data)
        return AdvisorDecision(
            suggest: decoded.suggest, stopId: decoded.stopId, urgency: decoded.urgency, reason: decoded.reason,
            message: decoded.message, traceId: decoded.traceId)
    }
}

enum AdvisorClientError: Error {
    case unexpectedResponse
}

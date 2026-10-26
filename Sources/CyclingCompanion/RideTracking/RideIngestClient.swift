import Foundation

struct RideIngestRequestPayload: Codable {
    let routeId: String
    let startTime: Date
    let endTime: Date
    let totalDistanceMeters: Double
    let totalMovingTimeSeconds: Double
    let stopsTaken: Int
    let outcome: String
    let featureSnapshots: [FeatureSnapshotPayload]
    /// The rider's answer to each stop suggestion this ride (RULE-18 in milestone 7's rules.md).
    /// Optional, so queued uploads written before it existed still decode, and omitted from the
    /// JSON when absent.
    var suggestionResponses: [SuggestionResponsePayload]? = nil
    /// Milestone 9 (RULE-19): the local ride id the advisor calls were made with, so the backend can
    /// link this ride to its traces. Filled in at send time when missing, so uploads queued before it
    /// existed get it too.
    var clientRideId: String? = nil

    /// This payload linked to the ride with local id `rideId`; a ride id it already carries is kept.
    func linked(toRide rideId: String) -> RideIngestRequestPayload {
        var linked = self
        linked.clientRideId = clientRideId ?? rideId
        return linked
    }
}

/// One suggestion answer as uploaded: stop id only — no coordinates (AC-68) — and the uppercase
/// answer, matching `outcome`'s wire form. `traceId` (milestone 9) links it to the advisor trace
/// of a remote suggestion; it is left out of the JSON when the suggestion has none.
struct SuggestionResponsePayload: Codable, Equatable {
    let stopId: Int64
    let suggestedAt: Date
    let response: String
    let respondedAt: Date?
    let traceId: String?

    init(_ response: SuggestionResponse) {
        self.stopId = response.stopId
        self.suggestedAt = response.suggestedAt
        self.response = response.answer.rawValue
        self.respondedAt = response.respondedAt
        self.traceId = response.traceId
    }
}

private struct RideIngestResponsePayload: Decodable {
    let rideId: String
}

/// Uploads a finished ride (RULE-5/RULE-7 in spec/rules.md, AC-4/AC-5/AC-6) — shaped like
/// `AdvisorClient`: an actor, injected `HTTPTransport`/`AuthStubClient`/`LazySignIn`, reuses the
/// existing transparent sign-in flow (no second sign-in path). Returns `false` (never throws)
/// for every failure case, so `RideFinisher` has one uniform "upload failed, queue it" signal.
actor RideIngestClient {
    private static let log = Log.logger(category: "RideIngest")

    private let baseURL: URL
    private let authClient: AuthStubClient
    private let lazySignIn: LazySignIn
    private let transport: HTTPTransport

    init(baseURL: URL, authClient: AuthStubClient, lazySignIn: LazySignIn, transport: HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.authClient = authClient
        self.lazySignIn = lazySignIn
        self.transport = transport
    }

    /// Sends `payload` linked to `rideId`, the local id of the ride it describes (RULE-19). `nil` only
    /// for an old queued upload whose ride can't be told; it then goes unlinked.
    @discardableResult
    func ingest(_ payload: RideIngestRequestPayload, rideId: String?) async -> Bool {
        let payload = rideId.map(payload.linked(toRide:)) ?? payload
        do {
            try await lazySignIn.ensureSignedIn()

            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/rides"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(payload)
            let authorized = try await authClient.authorize(request)

            let (data, response) = try await transport.data(for: authorized)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                Self.log.notice("Ride ingest failed with a non-2xx response — will be queued for retry")
                return false
            }
            let decoded = try JSONDecoder().decode(RideIngestResponsePayload.self, from: data)
            Self.log.info("Ride ingested: \(decoded.rideId, privacy: .public)")
            return true
        } catch {
            Self.log.notice("Ride ingest failed: \(String(describing: error), privacy: .public) — will be queued for retry")
            return false
        }
    }
}

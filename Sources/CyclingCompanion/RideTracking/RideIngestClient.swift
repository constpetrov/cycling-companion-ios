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

    @discardableResult
    func ingest(_ payload: RideIngestRequestPayload) async -> Bool {
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

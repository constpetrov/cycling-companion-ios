import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.4 validation (RULE-7 in spec/rules.md, AC-5/AC-6, Risk Hotspot 5 in spec/review.md).
final class PendingRideUploadQueueTests: XCTestCase {

    private func freshQueue() -> PendingRideUploadQueue {
        PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    private func payload(routeId: String = "route-1") -> RideIngestRequestPayload {
        RideIngestRequestPayload(
            routeId: routeId, startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 3_600),
            totalDistanceMeters: 20_000, totalMovingTimeSeconds: 3_600, stopsTaken: 0, outcome: "TYPICAL",
            featureSnapshots: [])
    }

    func testAnEmptyQueueFetchesNothing() async throws {
        let queue = freshQueue()

        let pending = try await queue.fetchAllOldestFirst()

        XCTAssertTrue(pending.isEmpty)
    }

    func testEnqueuedUploadsAreFetchedOldestFirst() async throws {
        let queue = freshQueue()
        try await queue.enqueue(payload(routeId: "route-first"), id: "ride-first")
        try await queue.enqueue(payload(routeId: "route-second"), id: "ride-second")

        let pending = try await queue.fetchAllOldestFirst()

        XCTAssertEqual(pending.map(\.payload.routeId), ["route-first", "route-second"])
    }

    func testRemovingAnUploadByIdDropsOnlyThatOne() async throws {
        let queue = freshQueue()
        try await queue.enqueue(payload(routeId: "route-first"), id: "ride-first")
        try await queue.enqueue(payload(routeId: "route-second"), id: "ride-second")
        let pendingBeforeRemoval = try await queue.fetchAllOldestFirst()

        try await queue.remove(id: pendingBeforeRemoval[0].id)

        let pendingAfterRemoval = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(pendingAfterRemoval.map(\.payload.routeId), ["route-second"])
    }

    func testQueueStatePersistsAcrossInstancesOfTheSameFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let firstInstance = PendingRideUploadQueue(fileURL: fileURL)
        try await firstInstance.enqueue(payload(), id: "ride-1")

        let secondInstance = PendingRideUploadQueue(fileURL: fileURL)
        let pending = try await secondInstance.fetchAllOldestFirst()

        XCTAssertEqual(pending.count, 1)
    }
}

/// task-2.4 validation (RULE-7, Risk Hotspot 5): retrying is bounded per launch, not an
/// unbounded serial retry of an arbitrarily large backlog.
final class PendingRideUploadRetrierTests: XCTestCase {

    private actor CountingSucceedingTransport: HTTPTransport {
        private(set) var ridesCallCount = 0

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url!.path
            let body: Data
            if path.hasSuffix("sign-in") {
                body = #"{"token":"stub-jwt","riderId":"11111111-1111-1111-1111-111111111111"}"#.data(using: .utf8)!
            } else {
                ridesCallCount += 1
                body = #"{"rideId":"22222222-2222-2222-2222-222222222222"}"#.data(using: .utf8)!
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private func payload(routeId: String) -> RideIngestRequestPayload {
        RideIngestRequestPayload(
            routeId: routeId, startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 3_600),
            totalDistanceMeters: 20_000, totalMovingTimeSeconds: 3_600, stopsTaken: 0, outcome: "TYPICAL",
            featureSnapshots: [])
    }

    @MainActor
    func testRetryingClearsASuccessfulUploadFromTheQueue() async throws {
        let queue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await queue.enqueue(payload(routeId: "route-1"), id: "ride-1")
        let transport = CountingSucceedingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            lazySignIn: LazySignIn(authClient: authClient), transport: transport)

        await retrier(queue: queue, ingestClient: ingestClient).retryPendingUploads()

        let remaining = try await queue.fetchAllOldestFirst()
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testRetryingIsBoundedToTheMaxBatchSizePerLaunch() async throws {
        let queue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let totalPending = PendingRideUploadRetrier.maxUploadsPerLaunch + 3
        for index in 0..<totalPending {
            try await queue.enqueue(payload(routeId: "route-\(index)"), id: "ride-\(index)")
        }
        let transport = CountingSucceedingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            lazySignIn: LazySignIn(authClient: authClient), transport: transport)

        await retrier(queue: queue, ingestClient: ingestClient).retryPendingUploads()

        let remaining = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(
            remaining.count, totalPending - PendingRideUploadRetrier.maxUploadsPerLaunch,
            "only the bounded batch size must be attempted in one retry pass")
        let calls = await transport.ridesCallCount
        XCTAssertEqual(calls, PendingRideUploadRetrier.maxUploadsPerLaunch)
    }

    private func retrier(
        queue: PendingRideUploadQueue, ingestClient: RideIngestClient, rideStore: RideStore? = nil
    ) -> PendingRideUploadRetrier {
        PendingRideUploadRetrier(
            pendingUploadQueue: queue, rideIngestClient: ingestClient,
            rideStore: rideStore
                ?? RideStore(
                    fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    }

    // MARK: - Milestone 9 AC-69 (RULE-19)

    private static let legacyPayloadJSON = #"""
        {"routeId":"route-1","startTime":0,"endTime":3600,"totalDistanceMeters":20000,
         "totalMovingTimeSeconds":3600,"stopsTaken":0,"outcome":"TYPICAL","featureSnapshots":[]}
        """#

    /// Sends one queued upload, written as `entryJSON` by some earlier build, and returns the
    /// `clientRideId` it went with. `savedRideIds` are the rides on the phone.
    @MainActor
    private func clientRideIdSent(forQueued entryJSON: String, savedRideIds: [String] = []) async throws -> String? {
        let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("[\(entryJSON)]".utf8).write(to: queueURL)
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        for id in savedRideIds {
            try await rideStore.persist(
                PersistedRide(
                    id: id, routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
                    endTime: Date(timeIntervalSince1970: 3_600), totalDistanceMeters: 20_000,
                    totalMovingTimeSeconds: 3_600, track: []))
        }
        let transport = RecordingIngestTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            lazySignIn: LazySignIn(authClient: authClient), transport: transport)

        await retrier(queue: PendingRideUploadQueue(fileURL: queueURL), ingestClient: ingestClient, rideStore: rideStore)
            .retryPendingUploads()

        let sent = await transport.sentClientRideIds
        XCTAssertEqual(sent.count, 1)
        return try XCTUnwrap(sent.first)
    }

    /// An upload queued under its ride id by a build without clientRideId is sent with that ride id.
    @MainActor
    func testAnUploadQueuedUnderItsRideIdByAnOlderBuildIsSentWithIt() async throws {
        let sent = try await clientRideIdSent(
            forQueued: #"{"id":"local-ride-old","enqueuedAt":0,"payload":\#(Self.legacyPayloadJSON)}"#,
            savedRideIds: ["local-ride-old"])

        XCTAssertEqual(sent, "local-ride-old")
    }

    /// Builds before the queue was keyed by ride id queued under a random id; no ride has it, so the
    /// upload goes unlinked rather than linked to a made-up ride.
    @MainActor
    func testAnUploadQueuedUnderARandomIdIsSentWithoutAClientRideId() async throws {
        let sent = try await clientRideIdSent(
            forQueued: #"{"id":"9b2e4f00-0000-4000-8000-000000000000","enqueuedAt":0,"payload":\#(Self.legacyPayloadJSON)}"#,
            savedRideIds: ["local-ride-other"])

        XCTAssertNil(sent)
    }

    /// An upload queued since milestone 9 keeps the ride id it was queued with.
    @MainActor
    func testAnUploadQueuedWithAClientRideIdKeepsIt() async throws {
        let payload = Self.legacyPayloadJSON.replacingOccurrences(
            of: #""featureSnapshots":[]"#, with: #""featureSnapshots":[],"clientRideId":"local-ride-new""#)

        let sent = try await clientRideIdSent(forQueued: #"{"id":"local-ride-new","enqueuedAt":0,"payload":\#(payload)}"#)

        XCTAssertEqual(sent, "local-ride-new")
    }
}

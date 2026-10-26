import XCTest

@testable import CyclingCompanion

/// Records the `clientRideId` of every ride ingest it is sent; ingest succeeds or fails on demand and
/// sign-in always succeeds. Shared by the upload and queue retry tests.
actor RecordingIngestTransport: HTTPTransport {
    var ingestSucceeds: Bool
    /// The `clientRideId` of each ingest request, in order (`nil` where absent).
    private(set) var sentClientRideIds: [String?] = []

    var ingestCalls: Int { sentClientRideIds.count }

    init(ingestSucceeds: Bool = true) {
        self.ingestSucceeds = ingestSucceeds
    }

    func setIngestSucceeds(_ value: Bool) {
        ingestSucceeds = value
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        let status: Int
        let body: String
        if path.hasSuffix("sign-in") {
            (status, body) = (200, #"{"token":"t","riderId":"11111111-1111-1111-1111-111111111111"}"#)
        } else {
            let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            sentClientRideIds.append(json?["clientRideId"] as? String)
            (status, body) = ingestSucceeds ? (200, #"{"rideId":"22222222-2222-2222-2222-222222222222"}"#) : (503, "")
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// task-3.2 (RULE-22): AC-79 to AC-83.
final class RideUploaderTests: XCTestCase {

    private func payload() -> RideIngestRequestPayload {
        RideIngestRequestPayload(
            routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 3_600),
            totalDistanceMeters: 20_000, totalMovingTimeSeconds: 3_600, stopsTaken: 0, outcome: "TYPICAL",
            featureSnapshots: [])
    }

    @MainActor
    private func uploader(_ transport: HTTPTransport) -> (RideUploader, PendingRideUploadQueue) {
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let client = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            lazySignIn: LazySignIn(authClient: authClient), transport: transport)
        let queue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return (RideUploader(ingestClient: client, queue: queue), queue)
    }

    @MainActor
    func testNoStatusBeforeAnyUpload() {
        let (uploader, _) = uploader(RecordingIngestTransport(ingestSucceeds: true))
        XCTAssertNil(uploader.status)
    }

    /// AC-79/AC-80: uploading, then saved; nothing queued.
    @MainActor
    func testSuccessfulUploadEndsSaved() async throws {
        let (uploader, queue) = uploader(RecordingIngestTransport(ingestSucceeds: true))

        await uploader.upload(payload(), rideId: "ride-1")

        XCTAssertEqual(uploader.status, .saved)
        let queued = try await queue.fetchAllOldestFirst()
        XCTAssertTrue(queued.isEmpty)
    }

    /// AC-79: while the request is in flight the status is uploading.
    @MainActor
    func testStatusIsUploadingWhileTheRequestIsInFlight() async {
        let (uploader, _) = uploader(RecordingIngestTransport(ingestSucceeds: true))

        let task = Task { await uploader.upload(payload(), rideId: "ride-1") }
        await Task.yield()
        XCTAssertEqual(uploader.status, .uploading)
        await task.value
    }

    /// AC-81: a failed upload is queued once, under the ride's id.
    @MainActor
    func testFailedUploadIsQueuedUnderTheRideId() async throws {
        let (uploader, queue) = uploader(RecordingIngestTransport(ingestSucceeds: false))

        await uploader.upload(payload(), rideId: "ride-1")

        XCTAssertEqual(uploader.status, .queued)
        let queued = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(queued.map(\.id), ["ride-1"])
    }

    /// AC-82: Retry now succeeding empties the queue and shows saved.
    @MainActor
    func testRetryNowSuccessRemovesTheRideFromTheQueue() async throws {
        let transport = RecordingIngestTransport(ingestSucceeds: false)
        let (uploader, queue) = uploader(transport)
        await uploader.upload(payload(), rideId: "ride-1")
        await transport.setIngestSucceeds(true)

        await uploader.retryNow()

        XCTAssertEqual(uploader.status, .saved)
        let queued = try await queue.fetchAllOldestFirst()
        XCTAssertTrue(queued.isEmpty)
    }

    /// AC-83: Retry now failing again keeps exactly one queue entry.
    @MainActor
    func testRetryNowFailureKeepsExactlyOneQueueEntry() async throws {
        let (uploader, queue) = uploader(RecordingIngestTransport(ingestSucceeds: false))
        await uploader.upload(payload(), rideId: "ride-1")

        await uploader.retryNow()
        await uploader.retryNow()

        XCTAssertEqual(uploader.status, .queued)
        let queued = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(queued.map(\.id), ["ride-1"])
    }

    @MainActor
    func testRetryNowDoesNothingUnlessQueued() async {
        let transport = RecordingIngestTransport(ingestSucceeds: true)
        let (uploader, _) = uploader(transport)
        await uploader.upload(payload(), rideId: "ride-1")
        let callsAfterUpload = await transport.ingestCalls

        await uploader.retryNow()

        let calls = await transport.ingestCalls
        XCTAssertEqual(calls, callsAfterUpload)
        XCTAssertEqual(uploader.status, .saved)
    }

    // MARK: - Milestone 9 task-3.4 (RULE-19): AC-68, AC-69

    /// AC-68.
    @MainActor
    func testAnUploadSendsTheLocalRideIdAsTheClientRideId() async {
        let transport = RecordingIngestTransport(ingestSucceeds: true)
        let (uploader, _) = uploader(transport)

        await uploader.upload(payload(), rideId: "local-ride-7")

        let sent = await transport.sentClientRideIds
        XCTAssertEqual(sent, ["local-ride-7"])
    }

    /// AC-69: Retry now sends it again, and the queued copy carries it too.
    @MainActor
    func testRetryNowSendsTheClientRideIdAndTheQueuedCopyKeepsIt() async throws {
        let transport = RecordingIngestTransport(ingestSucceeds: false)
        let (uploader, queue) = uploader(transport)
        await uploader.upload(payload(), rideId: "local-ride-8")
        await transport.setIngestSucceeds(true)

        await uploader.retryNow()

        let sent = await transport.sentClientRideIds
        XCTAssertEqual(sent, ["local-ride-8", "local-ride-8"])
        XCTAssertEqual(uploader.status, .saved)
        let queued = try await queue.fetchAllOldestFirst()
        XCTAssertTrue(queued.isEmpty)
    }
}

/// RULE-22: the pending queue is keyed by id; re-enqueueing replaces, and files written by older
/// builds (random ids) still load.
final class PendingRideUploadQueueKeyingTests: XCTestCase {

    private func payload(routeId: String) -> RideIngestRequestPayload {
        RideIngestRequestPayload(
            routeId: routeId, startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 60),
            totalDistanceMeters: 1, totalMovingTimeSeconds: 1, stopsTaken: 0, outcome: "TYPICAL", featureSnapshots: [])
    }

    func testEnqueueingTheSameIdReplacesTheEntry() async throws {
        let queue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))

        try await queue.enqueue(payload(routeId: "first"), id: "ride-1")
        try await queue.enqueue(payload(routeId: "second"), id: "ride-1")

        let all = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.payload.routeId, "second")
    }

    func testAQueueFileFromAnOlderBuildStillLoads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let older = PendingRideUploadQueue(fileURL: url)
        try await older.enqueue(payload(routeId: "legacy"), id: UUID().uuidString)  // random id, as before

        let reloaded = try await PendingRideUploadQueue(fileURL: url).fetchAllOldestFirst()

        XCTAssertEqual(reloaded.map(\.payload.routeId), ["legacy"])
    }
}

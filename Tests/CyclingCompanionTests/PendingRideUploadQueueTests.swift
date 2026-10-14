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
        try await queue.enqueue(payload(routeId: "route-first"))
        try await queue.enqueue(payload(routeId: "route-second"))

        let pending = try await queue.fetchAllOldestFirst()

        XCTAssertEqual(pending.map(\.payload.routeId), ["route-first", "route-second"])
    }

    func testRemovingAnUploadByIdDropsOnlyThatOne() async throws {
        let queue = freshQueue()
        try await queue.enqueue(payload(routeId: "route-first"))
        try await queue.enqueue(payload(routeId: "route-second"))
        let pendingBeforeRemoval = try await queue.fetchAllOldestFirst()

        try await queue.remove(id: pendingBeforeRemoval[0].id)

        let pendingAfterRemoval = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(pendingAfterRemoval.map(\.payload.routeId), ["route-second"])
    }

    func testQueueStatePersistsAcrossInstancesOfTheSameFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let firstInstance = PendingRideUploadQueue(fileURL: fileURL)
        try await firstInstance.enqueue(payload())

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
        try await queue.enqueue(payload(routeId: "route-1"))
        let transport = CountingSucceedingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            lazySignIn: LazySignIn(authClient: authClient), transport: transport)

        await PendingRideUploadRetrier(pendingUploadQueue: queue, rideIngestClient: ingestClient).retryPendingUploads()

        let remaining = try await queue.fetchAllOldestFirst()
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testRetryingIsBoundedToTheMaxBatchSizePerLaunch() async throws {
        let queue = PendingRideUploadQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let totalPending = PendingRideUploadRetrier.maxUploadsPerLaunch + 3
        for index in 0..<totalPending {
            try await queue.enqueue(payload(routeId: "route-\(index)"))
        }
        let transport = CountingSucceedingTransport()
        let authClient = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        let ingestClient = RideIngestClient(
            baseURL: URL(string: "https://backend.example.com")!, authClient: authClient,
            lazySignIn: LazySignIn(authClient: authClient), transport: transport)

        await PendingRideUploadRetrier(pendingUploadQueue: queue, rideIngestClient: ingestClient).retryPendingUploads()

        let remaining = try await queue.fetchAllOldestFirst()
        XCTAssertEqual(
            remaining.count, totalPending - PendingRideUploadRetrier.maxUploadsPerLaunch,
            "only the bounded batch size must be attempted in one retry pass")
        let calls = await transport.ridesCallCount
        XCTAssertEqual(calls, PendingRideUploadRetrier.maxUploadsPerLaunch)
    }
}

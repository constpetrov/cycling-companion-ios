import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-3.3 (RULE-9/RULE-22): AC-78 to AC-81, AC-84.
final class RideSummaryViewModelTests: XCTestCase {

    private let german = Locale(identifier: "de_DE")

    private func ride() -> PersistedRide {
        PersistedRide(
            id: "ride-1", routeId: "route-1", startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 4_000), totalDistanceMeters: 25_000, totalMovingTimeSeconds: 3_600,
            track: [])
    }

    @MainActor
    private func uploader(ingestSucceeds: Bool) -> RideUploader {
        let transport = FixedStatusTransport(ingestStatus: ingestSucceeds ? 200 : 503)
        return RideUploader(
            ingestClient: RideIngestClient(baseURL: TestAuth.baseURL, session: TestAuth.session(transport: transport)),
            queue: PendingRideUploadQueue(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    }

    private func payload() -> RideIngestRequestPayload {
        RideIngestRequestPayload(
            routeId: "route-1", startTime: Date(timeIntervalSince1970: 0), endTime: Date(timeIntervalSince1970: 4_000),
            totalDistanceMeters: 25_000, totalMovingTimeSeconds: 3_600, stopsTaken: 0, outcome: "TYPICAL",
            featureSnapshots: [])
    }

    /// AC-78: distance, moving time, average moving speed, stops taken, suggestions.
    @MainActor
    func testShowsTheFinishedRidesFigures() {
        let viewModel = RideSummaryViewModel(
            outcome: .saved(ride()), uploader: uploader(ingestSucceeds: true), decisionLog: DecisionLog(), locale: german)

        XCTAssertTrue(viewModel.distanceText?.contains("25") ?? false)
        XCTAssertTrue(viewModel.distanceText?.contains("km") ?? false)
        XCTAssertNotNil(viewModel.movingTimeText)
        XCTAssertTrue(viewModel.averageSpeedText?.contains("25,0") ?? false, "25 km in 1 h of moving time")
        XCTAssertEqual(viewModel.stopsTaken, 0)
        XCTAssertEqual(viewModel.suggestionsText, "No stop suggestions")
        XCTAssertNil(viewModel.notSavedMessage)
    }

    /// AC-79/AC-80: uploading until the uploader reports saved.
    @MainActor
    func testUploadStatusFollowsTheUploader() async {
        let uploader = uploader(ingestSucceeds: true)
        let viewModel = RideSummaryViewModel(outcome: .saved(ride()), uploader: uploader, decisionLog: DecisionLog())
        XCTAssertEqual(viewModel.uploadStatusText, "Uploading…")

        await uploader.upload(payload(), rideId: "ride-1")

        XCTAssertEqual(viewModel.uploadStatusText, "Saved")
        XCTAssertFalse(viewModel.showsRetryNow)
    }

    /// AC-81: a failed upload shows queued with Retry now.
    @MainActor
    func testQueuedUploadOffersRetryNow() async {
        let uploader = uploader(ingestSucceeds: false)
        let viewModel = RideSummaryViewModel(outcome: .saved(ride()), uploader: uploader, decisionLog: DecisionLog())

        await uploader.upload(payload(), rideId: "ride-1")

        XCTAssertEqual(viewModel.uploadStatusText, "Queued — will retry")
        XCTAssertTrue(viewModel.showsRetryNow)
    }

    /// AC-84: not saved → the message, and no figures or upload status.
    @MainActor
    func testNotSavedShowsTheMessageOnly() {
        let viewModel = RideSummaryViewModel(
            outcome: .notSaved, uploader: uploader(ingestSucceeds: true), decisionLog: DecisionLog())

        XCTAssertEqual(
            viewModel.notSavedMessage, "Couldn't save this ride — it will resume next time you open the app")
        XCTAssertNil(viewModel.distanceText)
        XCTAssertNil(viewModel.uploadStatusText)
        XCTAssertFalse(viewModel.showsRetryNow)
    }
}

private struct FixedStatusTransport: HTTPTransport {
    let ingestStatus: Int

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isSignIn = request.url!.path.hasSuffix("sign-in")
        let status = isSignIn ? 200 : ingestStatus
        let body = isSignIn
            ? #"{"token":"t","riderId":"11111111-1111-1111-1111-111111111111"}"#
            : #"{"rideId":"22222222-2222-2222-2222-222222222222"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

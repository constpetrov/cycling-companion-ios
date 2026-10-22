import RoutePersistence
import UserNotifications
import XCTest

@testable import CyclingCompanion

/// task-4.2 validation (RULE-24 in spec/rules.md, AC-39/AC-40/AC-42).
final class NotifierTests: XCTestCase {

    private func candidate(osmId: Int64 = 1, name: String = "Café Sample") -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: osmId, type: "CAFE_BAKERY_RESTAURANT", name: name, latitude: 52.5, longitude: 13.4,
            kmMarkMeters: 1_000, detourMeters: 300, openingHours: nil)
    }

    private func approved(stopId: String = "1") -> AdvisorDecision {
        AdvisorDecision(suggest: true, stopId: stopId, urgency: "normal", reason: nil, message: "a stop is coming up")
    }

    // MARK: - Lazy permission request (AC-39)

    /// Milestone 7 RULE-21: permission is asked for only from the pre-ride readiness check. Mid-ride,
    /// an undetermined permission means nothing is posted (the dashboard card still shows).
    func testPermissionIsNeverRequestedMidRide() async throws {
        let scheduling = FakeNotificationScheduling(grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())

        try await notifier.notify(verdict: approved(), candidates: [candidate()])

        let callCount = await scheduling.requestAuthorizationCallCount
        XCTAssertEqual(callCount, 0)
        let posted = await scheduling.addedRequests
        XCTAssertTrue(posted.isEmpty)
    }

    func testProvisionalPermissionStillPosts() async throws {
        let scheduling = FakeNotificationScheduling(initialStatus: .provisional, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())

        try await notifier.notify(verdict: approved(), candidates: [candidate()])

        let posted = await scheduling.addedRequests
        XCTAssertEqual(posted.count, 1)
    }

    func testPermissionIsNotRequestedWhenAlreadyAuthorized() async throws {
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())

        try await notifier.notify(verdict: approved(), candidates: [candidate()])

        let callCount = await scheduling.requestAuthorizationCallCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - Posting when authorized (AC-40/AC-42)

    func testApprovedSuggestionPostsANotificationNamingTheStopWhenAlreadyAuthorized() async throws {
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())

        try await notifier.notify(verdict: approved(), candidates: [candidate(name: "Bakery")])

        let posted = await scheduling.addedRequests
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.content.title, "Bakery")
    }

    func testPostedRequestUserInfoCarriesTheStopsMapLocation() async throws {
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())

        try await notifier.notify(verdict: approved(), candidates: [candidate()])

        let posted = await scheduling.addedRequests
        let userInfo = posted.first?.content.userInfo
        XCTAssertEqual(userInfo?["latitude"] as? Double, 52.5)
        XCTAssertEqual(userInfo?["longitude"] as? Double, 13.4)
        XCTAssertEqual(userInfo?["stopId"] as? String, "1")
    }

    // MARK: - Nothing to notify about

    func testRejectedVerdictPostsNothing() async throws {
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let notifier = Notifier(scheduling: scheduling, log: DecisionLog())
        let rejected = AdvisorDecision(suggest: false, stopId: nil, urgency: nil, reason: nil, message: nil)

        try await notifier.notify(verdict: rejected, candidates: [candidate()])

        let posted = await scheduling.addedRequests
        XCTAssertTrue(posted.isEmpty)
        let callCount = await scheduling.requestAuthorizationCallCount
        XCTAssertEqual(callCount, 0, "no permission prompt should ever be triggered by a rejected verdict")
    }

    // MARK: - Every posted notification is recorded (AC-45)

    func testEveryPostedNotificationIsRecordedInTheDecisionLog() async throws {
        let scheduling = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)
        let log = DecisionLog()
        let notifier = Notifier(scheduling: scheduling, log: log)

        try await notifier.notify(verdict: approved(), candidates: [candidate()])

        XCTAssertEqual(log.postedNotifications.count, 1)
    }
}

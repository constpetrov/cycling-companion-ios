import UserNotifications
import XCTest

@testable import CyclingCompanion

/// task-4.1 validation (RULE-31 in spec/rules.md): proves the fake's own
/// `.notDetermined` -> request -> granted/denied transitions before `Notifier` ever uses it —
/// a review Risk Hotspot (notification-fake fidelity).
final class FakeNotificationSchedulingTests: XCTestCase {

    private func sampleRequest() -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: "sample", content: UNMutableNotificationContent(), trigger: nil)
    }

    func testStartsNotDetermined() async {
        let fake = FakeNotificationScheduling(grantOnRequest: true)

        let status = await fake.authorizationStatus()

        XCTAssertEqual(status, .notDetermined)
    }

    func testRequestAuthorizationGrantingTrueTransitionsToAuthorized() async throws {
        let fake = FakeNotificationScheduling(grantOnRequest: true)

        let granted = try await fake.requestAuthorization()

        XCTAssertTrue(granted)
        let status = await fake.authorizationStatus()
        XCTAssertEqual(status, .authorized)
    }

    func testRequestAuthorizationGrantingFalseTransitionsToDenied() async throws {
        let fake = FakeNotificationScheduling(grantOnRequest: false)

        let granted = try await fake.requestAuthorization()

        XCTAssertFalse(granted)
        let status = await fake.authorizationStatus()
        XCTAssertEqual(status, .denied)
    }

    func testReRequestingAnAlreadyDeterminedStatusDoesNotChangeIt() async throws {
        let fake = FakeNotificationScheduling(initialStatus: .denied, grantOnRequest: true)

        let granted = try await fake.requestAuthorization()

        XCTAssertFalse(granted)
        let status = await fake.authorizationStatus()
        XCTAssertEqual(status, .denied)
    }

    func testAddSucceedsOnlyWhenAuthorized() async throws {
        let fake = FakeNotificationScheduling(initialStatus: .authorized, grantOnRequest: true)

        try await fake.add(sampleRequest())

        let added = await fake.addedRequests
        XCTAssertEqual(added.count, 1)
    }

    func testAddThrowsWhenNotAuthorized() async {
        let fake = FakeNotificationScheduling(initialStatus: .denied, grantOnRequest: true)

        do {
            try await fake.add(sampleRequest())
            XCTFail("expected add(_:) to throw when not authorized")
        } catch {
            // expected
        }
    }

    func testAddThrowsWhileNotDetermined() async {
        let fake = FakeNotificationScheduling(grantOnRequest: true)

        do {
            try await fake.add(sampleRequest())
            XCTFail("expected add(_:) to throw before authorization is requested")
        } catch {
            // expected
        }
    }
}

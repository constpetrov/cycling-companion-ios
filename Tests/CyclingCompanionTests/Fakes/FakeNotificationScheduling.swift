import UserNotifications

@testable import CyclingCompanion

/// Models the `.notDetermined` -> request -> granted/denied transitions explicitly, rather
/// than a stubbed boolean (RULE-31 in spec/rules.md) — a fake this shallow could pass
/// `Notifier` tests while hiding a real bug in how permission state is read or requested.
actor FakeNotificationScheduling: NotificationScheduling {
    private var status: UNAuthorizationStatus
    private(set) var requestAuthorizationCallCount = 0
    private(set) var addedRequests: [UNNotificationRequest] = []

    /// `grantOnRequest` decides what `requestAuthorization()` transitions `status` to; it has
    /// no effect if `status` is already determined (matches the real API: re-requesting an
    /// already-decided permission doesn't re-prompt or change the outcome).
    private let grantOnRequest: Bool

    init(initialStatus: UNAuthorizationStatus = .notDetermined, grantOnRequest: Bool) {
        self.status = initialStatus
        self.grantOnRequest = grantOnRequest
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCount += 1
        if status == .notDetermined {
            status = grantOnRequest ? .authorized : .denied
        }
        return status == .authorized
    }

    func add(_ request: UNNotificationRequest) async throws {
        guard status == .authorized else {
            throw FakeNotificationSchedulingError.notAuthorized
        }
        addedRequests.append(request)
    }
}

enum FakeNotificationSchedulingError: Error {
    case notAuthorized
}

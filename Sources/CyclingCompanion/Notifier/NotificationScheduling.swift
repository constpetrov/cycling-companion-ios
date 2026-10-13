import UserNotifications

/// The `UNUserNotificationCenter` surface `Notifier` needs, as call/response methods rather
/// than a stream (RULE-31 in spec/rules.md) — `Notifier` needs point-in-time calls, not a
/// continuous feed, unlike `LocationSource`/`SensorSource`. Mirrors `HTTPTransport`'s
/// injected-dependency shape so tests never touch the real notification center.
protocol NotificationScheduling: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

/// `UNNotificationRequest` predates Swift concurrency and isn't audited `Sendable`, but it's
/// effectively immutable once built (no mutation after `UNNotificationRequest(identifier:
/// content:trigger:)`) — safe to share across the `NotificationScheduling`/`DecisionLog`
/// actor boundaries this protocol's `add(_:)` and the structured decision log cross.
extension UNNotificationRequest: @unchecked Sendable {}

extension UNUserNotificationCenter: NotificationScheduling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await requestAuthorization(options: [.alert, .sound])
    }
}

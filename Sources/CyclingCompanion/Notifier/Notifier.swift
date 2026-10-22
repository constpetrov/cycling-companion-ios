import RoutePersistence
import UserNotifications

/// Thin wrapper over `NotificationScheduling` (RULE-24/RULE-31 in spec/rules.md,
/// AC-39/AC-40/AC-42): requests permission only while not yet determined, right before the
/// first Guardrail-approved suggestion, then posts a local notification naming the stop with a
/// deep-link `userInfo` payload. Does nothing for a rejected/no-suggestion verdict.
actor Notifier {
    private static let osLog = Log.logger(category: "Notifier")

    private let scheduling: NotificationScheduling
    private let log: DecisionLog

    init(scheduling: NotificationScheduling, log: DecisionLog) {
        self.scheduling = scheduling
        self.log = log
    }

    func notify(verdict: AdvisorDecision, candidates: [PersistedPoiInput]) async throws {
        guard verdict.suggest, let stopId = verdict.stopId else {
            return
        }

        // Milestone 7 RULE-21: permission is only ever asked for from the pre-ride readiness check,
        // never mid-ride; without it the suggestion still shows on the dashboard card.
        let status = await scheduling.authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            Self.osLog.notice("Suppressing a suggested stop — notification permission not authorized")
            return
        }

        let candidate = candidates.first { String($0.osmId) == stopId }
        let content = UNMutableNotificationContent()
        content.title = candidate?.name ?? "A stop is coming up"
        content.body = verdict.message ?? ""
        content.userInfo = [
            "stopId": stopId,
            "latitude": candidate?.latitude ?? 0,
            "longitude": candidate?.longitude ?? 0,
        ]
        let request = UNNotificationRequest(identifier: stopId, content: content, trigger: nil)
        try await scheduling.add(request)
        log.recordPostedNotification(request)
        Self.osLog.info("Posted stop notification for stopId=\(stopId, privacy: .public)")
    }
}

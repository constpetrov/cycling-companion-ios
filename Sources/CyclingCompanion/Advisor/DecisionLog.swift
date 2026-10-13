import Foundation
import UserNotifications

/// Records every `LocalAdvisor` decision, every `GuardrailGate` verdict, and every
/// notification actually posted, read directly by tests (RULE-25 in spec/rules.md,
/// AC-41/AC-43/AC-44/AC-45) — independent of whether a notification was ultimately posted, and
/// independent of the OS's own delivery outcome.
///
/// A lock-guarded plain class rather than an actor, so `LocalAdvisor`/`GuardrailGate` can keep
/// logging as a synchronous side effect of their existing pure functions instead of becoming
/// async just to record an observation (RULE-25 explicitly allows either shape).
final class DecisionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _advisorDecisions: [AdvisorDecision] = []
    private var _guardrailVerdicts: [AdvisorDecision] = []
    private var _postedNotifications: [UNNotificationRequest] = []

    var advisorDecisions: [AdvisorDecision] {
        lock.withLock { _advisorDecisions }
    }

    var guardrailVerdicts: [AdvisorDecision] {
        lock.withLock { _guardrailVerdicts }
    }

    var postedNotifications: [UNNotificationRequest] {
        lock.withLock { _postedNotifications }
    }

    func recordAdvisorDecision(_ decision: AdvisorDecision) {
        lock.withLock { _advisorDecisions.append(decision) }
    }

    func recordGuardrailVerdict(_ verdict: AdvisorDecision) {
        lock.withLock { _guardrailVerdicts.append(verdict) }
    }

    func recordPostedNotification(_ request: UNNotificationRequest) {
        lock.withLock { _postedNotifications.append(request) }
    }
}

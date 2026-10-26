/// An advisor's decision (RULE-19 in spec/rules.md) — the same shape a future backend LLM
/// advisor would produce, so `GuardrailGate` stays the same component regardless of which
/// advisor produced it. `stopId`/`urgency`/`reason`/`message` are `nil` exactly when
/// `suggest` is `false`. `traceId` (milestone 9, RULE-32) is the backend trace a remote decision
/// was saved under; on-device decisions have none.
struct AdvisorDecision: Sendable {
    let suggest: Bool
    let stopId: String?
    let urgency: String?
    let reason: String?
    let message: String?
    var traceId: String? = nil
}

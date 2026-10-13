import Foundation
import RoutePersistence

/// The final say before any notification fires (RULE-22/RULE-23 in spec/rules.md,
/// AC-27 through AC-36): rejects a suggestion whose stop isn't in POI Lookahead's candidate
/// list, whose detour exceeds the cap, that arrives too soon after a prior approved suggestion,
/// or too soon after the rider last stopped. Passes an already-non-suggesting decision through
/// unchanged, and an approved one through unchanged if it clears every check.
///
/// RULE-23: `now` and the prior-suggestion/last-stop timestamps are all track-derived, supplied
/// by the caller — this type never calls `Date()` itself.
enum GuardrailGate {
    /// AC-28/AC-29/AC-30: design.md's own exact value — no further resolution needed.
    static let detourCapMeters: Double = 2_000
    /// AC-31/AC-32/AC-33: design.md's own exact value.
    static let rateLimitMinutes: Double = 30
    /// AC-34/AC-35/AC-36: design.md's own exact value.
    static let postStopQuietMinutes: Double = 10

    static func evaluate(
        decision: AdvisorDecision, candidates: [PersistedPoiInput], now: Date,
        lastApprovedSuggestionTimestamp: Date?, lastStopTimestamp: Date?, log: DecisionLog
    ) -> AdvisorDecision {
        let verdict = verdict(
            decision: decision, candidates: candidates, now: now,
            lastApprovedSuggestionTimestamp: lastApprovedSuggestionTimestamp, lastStopTimestamp: lastStopTimestamp)
        log.recordGuardrailVerdict(verdict)
        return verdict
    }

    private static func verdict(
        decision: AdvisorDecision, candidates: [PersistedPoiInput], now: Date,
        lastApprovedSuggestionTimestamp: Date?, lastStopTimestamp: Date?
    ) -> AdvisorDecision {
        guard decision.suggest, let stopId = decision.stopId else {
            return decision
        }
        guard let candidate = candidates.first(where: { String($0.osmId) == stopId }) else {
            return rejected
        }
        guard candidate.detourMeters <= Self.detourCapMeters else {
            return rejected
        }
        if let lastApprovedSuggestionTimestamp,
            now.timeIntervalSince(lastApprovedSuggestionTimestamp) < Self.rateLimitMinutes * 60
        {
            return rejected
        }
        if let lastStopTimestamp, now.timeIntervalSince(lastStopTimestamp) < Self.postStopQuietMinutes * 60 {
            return rejected
        }
        return decision
    }

    private static var rejected: AdvisorDecision {
        AdvisorDecision(suggest: false, stopId: nil, urgency: nil, reason: nil, message: nil)
    }
}

import Foundation
import RoutePersistence

/// Evaluates fixed rules against a feature snapshot and POI Lookahead's candidates, producing
/// an `AdvisorDecision` (RULE-19/RULE-20/RULE-21 in spec/rules.md, AC-25/AC-26).
enum LocalAdvisor {
    private static let urgency = "normal"

    /// AC-25: always returns a complete decision (never partial) — `suggest: false` with
    /// everything else `nil` if the trigger doesn't proceed, or if it did but there's no
    /// candidate to suggest (spec.md's handled edge case: zero candidates means no suggestion
    /// regardless of fatigue signals, even one the trigger itself fired on).
    static func decide(
        snapshot: FeatureSnapshot, candidates: [PersistedPoiInput], hasQualifyingStopAhead: Bool,
        secondsSinceLastCheckThatProceeded: TimeInterval, log: DecisionLog
    ) -> AdvisorDecision {
        guard
            LocalTrigger.shouldProceed(
                snapshot: snapshot, hasQualifyingStopAhead: hasQualifyingStopAhead,
                secondsSinceLastCheckThatProceeded: secondsSinceLastCheckThatProceeded),
            let bestCandidate = candidates.first
        else {
            log.recordAdvisorDecision(noSuggestion)
            return noSuggestion
        }

        let feature = LocalTrigger.crossedFeature(snapshot)
        let decision = AdvisorDecision(
            suggest: true, stopId: String(bestCandidate.osmId), urgency: Self.urgency, reason: feature?.rawValue,
            message: message(for: feature, stop: bestCandidate))
        log.recordAdvisorDecision(decision)
        return decision
    }

    private static var noSuggestion: AdvisorDecision {
        AdvisorDecision(suggest: false, stopId: nil, urgency: nil, reason: nil, message: nil)
    }

    /// AC-26/RULE-21: a plain Swift string template — no Foundation Models or other on-device
    /// LLM (already decided in spec.md). `feature` is `nil` when the trigger fired only
    /// because a qualifying stop is ahead, with no fatigue signal itself.
    private static func message(for feature: FatigueFeature?, stop: PersistedPoiInput) -> String {
        let name = stop.name ?? "a stop"
        let detourKm = String(format: "%.1f", stop.detourMeters / 1_000)
        guard let feature else {
            return "\(name) is coming up, \(detourKm) km off route."
        }
        switch feature {
        case .hrDrift:
            return "Your heart rate's drifting up for the pace — \(name) is \(detourKm) km off route."
        case .speedTrend:
            return "Your pace has been dropping — \(name) is \(detourKm) km off route."
        case .cadenceDrop:
            return "Your cadence is down from the start of the ride — \(name) is \(detourKm) km off route."
        }
    }
}

import Foundation

/// A fatigue signal that crossed its fixed threshold (RULE-20 in spec/rules.md) — `rawValue`
/// doubles as `AdvisorDecision.reason`'s text (RULE-21).
enum FatigueFeature: String, Sendable {
    case hrDrift = "HR drift"
    case speedTrend = "speed trend"
    case cadenceDrop = "cadence drop"
}

/// Decides whether to proceed to the Local Advisor (RULE-2/RULE-4 in spec/rules.md,
/// AC-13/AC-14/AC-15/AC-16/AC-17): a feature value crosses its fixed threshold, OR a
/// qualifying stop is coming up within POI Lookahead's range, OR 45 minutes have passed since
/// the last check that proceeded.
///
/// A pure function, tested via fixtures with explicit inputs — orchestrating *when* it's
/// actually called during a live ride (and what "since the last check that proceeded" means
/// before any check ever has, this milestone having no built orchestrator loop yet) is a
/// caller concern, not this function's. The documented convention for that bootstrapping case
/// is to pass elapsed time since ride start, mirroring how `timeSinceLastStopSeconds`
/// (task-2.5) falls back to ride start when no stop has occurred yet.
enum LocalTrigger {
    /// AC-13: uncalibrated starting values (review Risk Hotspot) — tune once real-ride data
    /// exists, same caveat as `FeatureEngine`'s own constants.
    private static let hrDriftThreshold: Double = 0.10
    /// A grade-adjusted speed decline of roughly 0.3 m/s over the 30-minute window
    /// `speedTrend` is computed over (task-2.3).
    private static let speedTrendThreshold: Double = -0.3 / (30 * 60)
    private static let cadenceDropThreshold: Int = -10
    /// AC-15/AC-16/AC-17.
    private static let fallbackIntervalSeconds: TimeInterval = 45 * 60

    static func shouldProceed(
        snapshot: FeatureSnapshot, hasQualifyingStopAhead: Bool, secondsSinceLastCheckThatProceeded: TimeInterval
    ) -> Bool {
        crossedFeature(snapshot) != nil || hasQualifyingStopAhead
            || secondsSinceLastCheckThatProceeded >= Self.fallbackIntervalSeconds
    }

    /// RULE-20: checked in priority order (HR drift -> speed trend -> cadence drop); returns
    /// the first one that crosses its threshold, or `nil` if none do. Shared with
    /// `LocalAdvisor` (task-3.2) for `reason` selection, so the two never disagree about
    /// which feature actually triggered.
    static func crossedFeature(_ snapshot: FeatureSnapshot) -> FatigueFeature? {
        if let hrDrift = snapshot.hrDrift, hrDrift > Self.hrDriftThreshold {
            return .hrDrift
        }
        if let speedTrend = snapshot.speedTrend, speedTrend < Self.speedTrendThreshold {
            return .speedTrend
        }
        if let cadenceDrop = snapshot.cadenceDrop, cadenceDrop <= Self.cadenceDropThreshold {
            return .cadenceDrop
        }
        return nil
    }
}

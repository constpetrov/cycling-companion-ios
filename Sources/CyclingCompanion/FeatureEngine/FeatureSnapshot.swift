import Foundation

/// A single 60-second fatigue-feature snapshot (RULE-4 in spec/rules.md) — one field per
/// design.md-named feature, `nil` meaning missing. Never persisted this milestone (spec.md's
/// explicit decision: nothing yet consumes an uploaded/persisted snapshot timeline).
struct FeatureSnapshot: Sendable {
    let timestamp: Date

    /// AC-2: always missing this milestone — no rider-profile/history storage.
    let speedVsBaseline: Double?
    /// AC-3: always missing this milestone — needs rider weight, which nothing collects yet.
    let workDone: Double?
    /// AC-4: always missing this milestone — needs cross-ride history.
    let rideSoFarVsLongest: Double?
    /// AC-5: always missing this milestone — needs a weather API (design.md marks it "(later)").
    let conditions: Double?

    /// AC-6/AC-56: grade-adjusted speed's 30-minute trailing slope.
    let speedTrend: Double?
    /// AC-7/AC-11/AC-56: this ride's own first-hour baseline; missing before that baseline
    /// exists or during a heart-rate dropout.
    let hrDrift: Double?
    /// AC-8/AC-12: current cadence minus the ride's first accepted reading; missing during a
    /// cadence dropout.
    let cadenceDrop: Int?
    /// AC-9: elapsed time since the most recent qualifying stop, or since ride start if none.
    let timeSinceLastStopSeconds: Double?
    /// AC-10/AC-54/AC-55: remaining route distance; frozen off-route.
    let remainingEffortMeters: Double?

    init(
        timestamp: Date, speedVsBaseline: Double? = nil, workDone: Double? = nil,
        rideSoFarVsLongest: Double? = nil, conditions: Double? = nil, speedTrend: Double? = nil,
        hrDrift: Double? = nil, cadenceDrop: Int? = nil, timeSinceLastStopSeconds: Double? = nil,
        remainingEffortMeters: Double? = nil
    ) {
        self.timestamp = timestamp
        self.speedVsBaseline = speedVsBaseline
        self.workDone = workDone
        self.rideSoFarVsLongest = rideSoFarVsLongest
        self.conditions = conditions
        self.speedTrend = speedTrend
        self.hrDrift = hrDrift
        self.cadenceDrop = cadenceDrop
        self.timeSinceLastStopSeconds = timeSinceLastStopSeconds
        self.remainingEffortMeters = remainingEffortMeters
    }
}

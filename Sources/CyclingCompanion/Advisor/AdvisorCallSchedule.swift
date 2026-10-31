import Foundation

/// How often a ride asks the remote Advisor. A stop within lookahead range trips `LocalTrigger` on
/// nearly every cycle, and each call keeps the cellular radio awake, so a call is only made for the
/// first check, a fatigue signal that differs from the last call's, or once the recheck interval has
/// passed. Compares against the last call's signal, not the previous cycle's, so a noisy signal that
/// flips on and off doesn't call again on every flip. Times are track-derived, like `GuardrailGate`'s.
struct AdvisorCallSchedule {
    static let recheckIntervalSeconds: TimeInterval = 10 * 60

    private var lastCallAt: Date?
    private var lastCallFeature: FatigueFeature?

    func isDue(crossedFeature: FatigueFeature?, now: Date) -> Bool {
        guard let lastCallAt else { return true }
        if let crossedFeature, crossedFeature != lastCallFeature { return true }
        return now.timeIntervalSince(lastCallAt) >= Self.recheckIntervalSeconds
    }

    mutating func recordCall(crossedFeature: FatigueFeature?, at now: Date) {
        lastCallAt = now
        lastCallFeature = crossedFeature
    }
}

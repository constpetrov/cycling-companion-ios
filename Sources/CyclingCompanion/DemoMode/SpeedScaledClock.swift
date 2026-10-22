import Foundation

/// A `Clock` that scales every `sleep(for:)` by `1/speed` (RULE-7 in spec/rules.md, AC-23) —
/// used only for a Demo Mode ride's `RideTracker`/`FeatureEngine`, so Feature Engine's
/// 60-second snapshot cadence scales with the replay speed instead of drifting out of sync
/// with an accelerated fixture. `DemoModeReplayDriver` itself (Milestone 3) keeps receiving a
/// plain, unscaled `SystemClock()` and continues doing its own internal `1/speed` division
/// unchanged — the two apply the same factor independently, with no double-scaling, since
/// neither reads the other's clock.
struct SpeedScaledClock: Clock {
    let base: Clock
    let speed: Double
    /// Where ride time and base time coincide; ride time runs `speed` times faster from here.
    let origin: Date

    init(base: Clock, speed: Double, origin: Date = Date()) {
        self.base = base
        self.speed = speed
        self.origin = origin
    }

    var now: Date {
        get async {
            let baseNow = await base.now
            return origin.addingTimeInterval(baseNow.timeIntervalSince(origin) * speed)
        }
    }

    func sleep(for seconds: TimeInterval) async throws {
        try await base.sleep(for: seconds / speed)
    }
}

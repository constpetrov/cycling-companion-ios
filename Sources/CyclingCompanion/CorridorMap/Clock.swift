import Foundation

/// Injected time source (architecture doc's testing convention: "never Date()/Timer directly").
/// Lets tests advance time deterministically instead of waiting on a real clock.
protocol Clock: Sendable {
    func sleep(for seconds: TimeInterval) async throws

    /// The current time on this clock (RULE-12 in milestone 7's rules.md). For a replay or
    /// speed-scaled clock this is ride time, advanced by what the clock has slept, so time-based
    /// checks (the 30 s no-GPS badge) run at replay speed. Async so actor-based clocks conform.
    var now: Date { get async }
}

struct SystemClock: Clock {
    var now: Date { Date() }

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

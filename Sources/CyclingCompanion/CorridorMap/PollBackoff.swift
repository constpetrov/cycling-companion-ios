import Foundation

/// The wait before each corridor status re-check while a route is `building` (milestone 8,
/// RULE-18): 2 s, growing by half each time, capped at 15 s. Building now only happens before the
/// backend's first stop import, which can take a couple of minutes, so there is no time limit.
struct PollBackoff: Sendable {
    static let first: TimeInterval = 2
    static let cap: TimeInterval = 15

    private var current: TimeInterval = PollBackoff.first

    mutating func next() -> TimeInterval {
        defer { current = min(PollBackoff.cap, current * 1.5) }
        return current
    }
}

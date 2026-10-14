import Foundation

/// Races `operation` against `clock.sleep(for: seconds)` and returns whichever finishes first
/// (RULE-13 in spec/rules.md) — `nil` if the deadline wins, or if `operation` itself throws.
/// Never relies on a raw wall-clock timeout (`URLRequest.timeoutInterval`): the deadline is
/// driven entirely by the injected `Clock`, so a fake clock makes every outcome — operation
/// wins, deadline wins, and the boundary between them — deterministically testable with no
/// real waiting (Risk Hotspot 2 in spec/review.md).
///
/// Whichever side loses the race is cancelled: for the production `URLSession`-backed
/// `HTTPTransport`, Task cancellation propagates into the underlying `URLSessionTask`, which is
/// what actually stops a timed-out network call rather than leaving it to finish unobserved.
func raceWithDeadline<T: Sendable>(
    seconds: TimeInterval, clock: Clock, operation: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            try? await operation()
        }
        group.addTask {
            try? await clock.sleep(for: seconds)
            return nil
        }
        guard let first = await group.next() else {
            group.cancelAll()
            return nil
        }
        group.cancelAll()
        return first
    }
}

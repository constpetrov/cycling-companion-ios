import Foundation

/// Injected time source (architecture doc's testing convention: "never Date()/Timer directly").
/// Lets tests advance time deterministically instead of waiting on a real clock.
protocol Clock: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemClock: Clock {
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

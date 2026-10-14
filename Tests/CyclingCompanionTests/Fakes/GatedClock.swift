import Foundation

@testable import CyclingCompanion

/// A `Clock` whose `sleep(for:)` call stays suspended until the test explicitly `release()`s
/// it — used to deterministically sequence `raceWithDeadline`'s two arms in tests without any
/// real waiting (`ReplayClock`'s instant resolution can't express "resolves after the operation
/// arm" or "resolves before it," only "resolves immediately" either way). Cancellation-aware
/// (`withTaskCancellationHandler`) so the losing side of a race actually unblocks instead of
/// leaving `withTaskGroup` waiting on it forever — structured concurrency's "the group doesn't
/// return until every child has finished" guarantee means an unresumed continuation here would
/// hang the test, not just leak a task.
actor GatedClock: Clock {
    private var continuation: CheckedContinuation<Void, Error>?
    /// Sticky, so a `release()` that arrives before `sleep(for:)` is ever called isn't lost —
    /// without this, `release()` would resume a still-nil `continuation` (a no-op), and the
    /// later `sleep(for:)` call would suspend forever with nothing left to wake it.
    private var released = false

    func sleep(for seconds: TimeInterval) async throws {
        if released { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.resumeWithCancellation() }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func resumeWithCancellation() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

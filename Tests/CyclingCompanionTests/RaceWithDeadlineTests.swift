import XCTest

@testable import CyclingCompanion

/// task-1.4 validation (RULE-13 in spec/rules.md, AC-3/AC-4/AC-5) — isolated tests for the
/// race helper itself, per Risk Hotspot 2 in spec/review.md, before it's wired into
/// `AdvisorClient`. Uses `GatedClock`/a gated operation closure to sequence outcomes
/// deterministically rather than depending on real timing.
final class RaceWithDeadlineTests: XCTestCase {

    func testOperationWinsWhenItCompletesBeforeTheDeadline() async {
        let clock = GatedClock()
        let gate = AsyncGate<String>()

        let resultTask = Task {
            await raceWithDeadline(seconds: 8.0, clock: clock) {
                try await gate.value()
            }
        }
        await gate.release(with: "decision")
        let result = await resultTask.value

        XCTAssertEqual(result, "decision", "the operation arm must win when it completes before the deadline fires")
    }

    func testDeadlineWinsWhenItFiresBeforeTheOperationCompletes() async {
        let clock = GatedClock()
        let gate = AsyncGate<String>()

        let resultTask = Task {
            await raceWithDeadline(seconds: 8.0, clock: clock) {
                try await gate.value()
            }
        }
        await clock.release()
        let result = await resultTask.value

        XCTAssertNil(result, "the deadline arm must win when it fires before the operation completes")
    }

    func testALateOperationResultAfterTheDeadlineHasAlreadyWonIsDiscarded() async {
        let clock = GatedClock()
        let gate = AsyncGate<String>()

        let resultTask = Task {
            await raceWithDeadline(seconds: 8.0, clock: clock) {
                try await gate.value()
            }
        }
        await clock.release()
        let result = await resultTask.value
        // The race has already returned nil. Releasing the operation afterward must not
        // retroactively change anything — there is no result left to update.
        await gate.release(with: "arrived after the deadline")

        XCTAssertNil(result)
    }

    func testOperationFailureIsTreatedTheSameAsATimeout() async {
        struct TestError: Error {}
        let clock = GatedClock()

        let result = await raceWithDeadline(seconds: 8.0, clock: clock) {
            throw TestError()
        }

        XCTAssertNil(result)
        await clock.release()
    }
}

/// A minimal async gate: `value()` suspends until `release(with:)` is called, letting a test
/// control exactly when the "operation" arm of a race resolves. Cancellation-aware for the
/// same reason `GatedClock`/`GatedTransport` are — otherwise the losing side of a race would
/// hang `withTaskGroup` forever instead of unblocking.
private actor AsyncGate<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    /// Sticky for the same reason `GatedClock.released` is (see its comment) — a `release`
    /// that arrives before `value()` is ever called must not be lost.
    private var releasedValue: T?

    func value() async throws -> T {
        if let releasedValue {
            return releasedValue
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.resumeWithCancellation() }
        }
    }

    func release(with value: T) {
        releasedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    private func resumeWithCancellation() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

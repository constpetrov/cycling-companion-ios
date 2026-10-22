import XCTest

@testable import CyclingCompanion

/// task-2.6 (RULE-14): AC-39 to AC-42. The 1.5 s timing itself is enforced by SwiftUI's long-press
/// gesture configured from `holdDuration`; these tests cover what happens on each gesture event.
final class HoldToConfirmTests: XCTestCase {

    func testHoldDurationIsOnePointFiveSeconds() {
        XCTAssertEqual(HoldToConfirmState.holdDuration, 1.5)
    }

    /// AC-39: released before the threshold — nothing confirmed, nothing changed.
    func testReleasingEarlyConfirmsNothing() {
        var state = HoldToConfirmState()

        state.pressingChanged(true)
        state.pressingChanged(false)

        XCTAssertFalse(state.isCompleted)
        XCTAssertEqual(state, HoldToConfirmState())
    }

    /// AC-40: the hold reaching the threshold confirms.
    func testReachingTheThresholdConfirms() {
        var state = HoldToConfirmState()
        state.pressingChanged(true)

        XCTAssertTrue(state.holdReachedThreshold())
        XCTAssertTrue(state.isCompleted)
    }

    /// AC-41: holding on past the threshold confirms exactly once.
    func testHoldingPastTheThresholdConfirmsOnce() {
        var state = HoldToConfirmState()
        state.pressingChanged(true)
        XCTAssertTrue(state.holdReachedThreshold())

        state.pressingChanged(true)
        XCTAssertFalse(state.holdReachedThreshold())
        state.pressingChanged(false)

        XCTAssertTrue(state.isCompleted)
    }

    /// AC-42: progress is shown while pressing.
    func testPressingIsReportedForTheProgressRing() {
        var state = HoldToConfirmState()

        state.pressingChanged(true)

        XCTAssertTrue(state.isPressing)
    }
}

import Foundation

@testable import CyclingCompanion

/// Shared fake `Clock` for RideTracking tests — records sleep calls without any real delay.
/// Named `ReplayClock` (not `FakeClock`) because a separate, private `FakeClock` already
/// exists in `CorridorPollingServiceTests.swift` for Milestone 1's own tests; Swift treats
/// top-level type names as module-wide even when one declaration is `private`, so the two
/// would collide. Left Milestone 1's file as-is since refactoring it is unrelated to this task.
actor ReplayClock: Clock {
    private var _sleepCalls: [TimeInterval] = []

    var sleepCalls: [TimeInterval] {
        _sleepCalls
    }

    func sleep(for seconds: TimeInterval) async throws {
        _sleepCalls.append(seconds)
    }
}

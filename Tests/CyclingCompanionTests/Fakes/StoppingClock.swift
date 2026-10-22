import Foundation

@testable import CyclingCompanion

/// A `Clock` whose sleeps return immediately (like `ReplayClock`) until `stopAfterSeconds` of
/// simulated time have passed, then throw `CancellationError` — so a poll loop with no time limit
/// can be run to a known point and inspected.
actor StoppingClock: Clock {
    private let stopAfterSeconds: TimeInterval
    private(set) var sleeps: [TimeInterval] = []
    private var _now = Date(timeIntervalSince1970: 0)

    init(stopAfterSeconds: TimeInterval) {
        self.stopAfterSeconds = stopAfterSeconds
    }

    var now: Date { _now }

    var totalSlept: TimeInterval { sleeps.reduce(0, +) }

    func sleep(for seconds: TimeInterval) async throws {
        guard totalSlept < stopAfterSeconds else { throw CancellationError() }
        sleeps.append(seconds)
        _now = _now.addingTimeInterval(seconds)
    }
}

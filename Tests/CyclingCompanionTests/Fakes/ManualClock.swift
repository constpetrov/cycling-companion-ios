import Foundation

@testable import CyclingCompanion

/// A `Clock` the test moves by hand. `sleep(for:)` never returns until cancelled, so loops driven
/// by it stay idle and the test calls their step method directly.
actor ManualClock: Clock {
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000)) {
        current = start
    }

    var now: Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    func sleep(for seconds: TimeInterval) async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
    }
}

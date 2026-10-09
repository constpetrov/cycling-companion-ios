import Foundation

@testable import CyclingCompanion

/// A `Clock` that performs a real, scaled sleep — used to prove AC-22: replaying the same
/// fixture under a faster virtual clock (`scale` < 1) must produce identical `RideTracker`
/// results to a real-time-paced run (`scale` == 1), since `RideTracker` reads elapsed time
/// from each fix's own timestamp, never from wall-clock or the `Clock` itself.
struct ScaledRealClock: Clock {
    let scale: Double

    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * scale * 1_000_000_000))
    }
}

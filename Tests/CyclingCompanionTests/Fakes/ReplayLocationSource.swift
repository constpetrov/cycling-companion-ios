import Foundation

@testable import CyclingCompanion

/// Replays a scripted sequence of `LocationFix` values, in order, with no pacing/delay of its
/// own — pacing for fixture replay is task-3.2's job, layered on top of this. Shared across
/// multiple test files in this milestone, so it lives in its own file rather than private to
/// one test case.
struct ReplayLocationSource: LocationSource {
    let fixes: [LocationFix]

    func locationUpdates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            for fix in fixes {
                continuation.yield(fix)
            }
            continuation.finish()
        }
    }
}

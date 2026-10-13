import Foundation

/// Replays a scripted sequence of `LocationFix` values, in order, with no pacing/delay of its
/// own — pacing for Demo Mode replay is `DemoModeReplayDriver`'s job, layered on top of this.
/// Promoted from the test target into the main target (RULE-26 in spec/rules.md, AC-46) so
/// `DemoMode` can reuse the exact mechanism already built and tested for fixture replay,
/// rather than a second implementation; `#if DEBUG` keeps it (and Demo Mode entirely) out of
/// Release builds (RULE-28).
#if DEBUG
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
#endif

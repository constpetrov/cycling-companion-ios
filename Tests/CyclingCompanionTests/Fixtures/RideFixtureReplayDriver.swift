import Foundation

@testable import CyclingCompanion

/// Feeds a fixture's combined, timestamp-ordered entries to `LocationSource`/`SensorSource`
/// off one shared, `Clock`-paced timeline (RULE-15/RULE-16 in spec/rules.md; AC-21/AC-22),
/// rather than two independently-scheduled streams: `locationUpdates()` and `sensorUpdates()`
/// both walk the *same* full entry list and sleep through the *same* sequence of inter-entry
/// delays (derived from the fixture's own timestamps, not wall-clock), each yielding only the
/// entries matching its own kind. Both streams therefore always advance through identical
/// clock positions in lockstep — pacing can never desync them — and swapping in a faster
/// `Clock` only changes how long replay takes, never what it produces (AC-22), since
/// `RideTracker` reads elapsed time from each fix's own timestamp, never from the clock.
struct RideFixtureReplayDriver: LocationSource, SensorSource {
    let entries: [RideFixtureEntry]
    let clock: Clock

    func locationUpdates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            Task {
                await replay { entry in
                    if let fix = entry.asLocationFix {
                        continuation.yield(fix)
                    }
                }
                continuation.finish()
            }
        }
    }

    func sensorUpdates() -> AsyncStream<SensorSample> {
        AsyncStream { continuation in
            Task {
                await replay { entry in
                    if let sample = entry.asSensorSample {
                        continuation.yield(sample)
                    }
                }
                continuation.finish()
            }
        }
    }

    private func replay(_ handle: (RideFixtureEntry) -> Void) async {
        var previousTimestamp: TimeInterval?
        for entry in entries {
            if let previous = previousTimestamp {
                let delay = entry.timestamp - previous
                if delay > 0 {
                    try? await clock.sleep(for: delay)
                }
            }
            previousTimestamp = entry.timestamp
            handle(entry)
        }
    }
}

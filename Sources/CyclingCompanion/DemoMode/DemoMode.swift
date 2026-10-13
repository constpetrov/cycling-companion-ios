import Foundation

/// `RideSession`'s cadence-gating predicate (RULE-3 in spec/rules.md, AC-12/AC-24): proceed if
/// forced OR the cadence has elapsed, the same bypass idiom `LocalTrigger.shouldProceed`'s
/// fallback-interval check already uses for "don't wait out the cadence." Needed in every
/// build — a live ride's cadence check calls it too, always with `forceRequested: false`, since
/// there's no way to request a force check outside Debug. Originally lived inside Demo Mode's
/// own `#if DEBUG` block (Milestone 3); relocated here (Milestone 4) once a live-driving loop
/// existed to actually call it for every ride, not just a demo one — same logic, same existing
/// test assertions, only where it's compiled changed.
enum AdvisorCheckCadence {
    /// AC-52: a forced check always proceeds immediately.
    static func shouldCheckNow(forceRequested: Bool, secondsSinceLastCheck: TimeInterval, cadenceSeconds: TimeInterval)
        -> Bool
    {
        forceRequested || secondsSinceLastCheck >= cadenceSeconds
    }
}

/// Internal demo/showcase harness (B-18/B-19/B-20 in spec/spec.md; RULE-27/RULE-28 in
/// spec/rules.md): replays a recorded ride fixture at an adjustable speed and can force the
/// next advisor check immediately. Compiled out of Release builds entirely via `#if DEBUG`
/// (RULE-28) so AC-53 holds unconditionally, not just behind a runtime flag.
#if DEBUG
enum DemoMode {
    static let speedRange: ClosedRange<Double> = 1...20

    /// AC-47 through AC-51: clamps a requested replay speed into `speedRange`.
    static func clampSpeed(_ requested: Double) -> Double {
        min(max(requested, speedRange.lowerBound), speedRange.upperBound)
    }
}

/// A `Clock`-paced replay of combined location+sensor fixture data off one shared timeline —
/// the same single-combined-list pattern `RideFixtureReplayDriver` already uses (so the two
/// streams can never desync, same reasoning as that type's own doc comment) — with
/// inter-sample delay scaled by `1 / speed` (RULE-27): a thin wrapper over the existing
/// Clock-paced replay driver, not a second pacing mechanism.
struct DemoModeReplayDriver: LocationSource, SensorSource {
    let locationFixes: [LocationFix]
    let sensorSamples: [SensorSample]
    let clock: Clock
    let speed: Double

    private enum Entry {
        case location(LocationFix)
        case sensor(SensorSample)

        var timestamp: Date {
            switch self {
            case .location(let fix): return fix.timestamp
            case .sensor(let sample): return sample.timestamp
            }
        }
    }

    private var combined: [Entry] {
        (locationFixes.map(Entry.location) + sensorSamples.map(Entry.sensor))
            .sorted { $0.timestamp < $1.timestamp }
    }

    func locationUpdates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            Task {
                await replay { entry in
                    if case .location(let fix) = entry { continuation.yield(fix) }
                }
                continuation.finish()
            }
        }
    }

    func sensorUpdates() -> AsyncStream<SensorSample> {
        AsyncStream { continuation in
            Task {
                await replay { entry in
                    if case .sensor(let sample) = entry { continuation.yield(sample) }
                }
                continuation.finish()
            }
        }
    }

    private func replay(_ handle: (Entry) -> Void) async {
        let effectiveSpeed = DemoMode.clampSpeed(speed)
        var previousTimestamp: Date?
        for entry in combined {
            if let previous = previousTimestamp {
                let delay = entry.timestamp.timeIntervalSince(previous)
                if delay > 0 {
                    try? await clock.sleep(for: delay / effectiveSpeed)
                }
            }
            previousTimestamp = entry.timestamp
            handle(entry)
        }
    }
}
#endif

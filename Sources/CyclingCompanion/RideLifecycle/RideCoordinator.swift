import Foundation
import RoutePersistence

/// The result of finishing a ride: either it was written to `RideStore` with its end time, or
/// the write failed and the unfinished checkpoint was kept so the ride resumes on next launch.
enum FinishOutcome {
    case saved(PersistedRide)
    case notSaved
}

/// What the full-screen ride cover shows (RULE-1/RULE-7 in milestone 7's rules.md). Kept separate
/// from `activeRide` so the cover stays up through the summary after the ride itself has ended.
enum RidePresentation: Identifiable {
    case live(LiveRide)
    case summary(FinishOutcome)

    var id: String {
        switch self {
        case .live(let ride): "live-\(ride.tracker.rideId)"
        case .summary: "summary"
        }
    }
}

/// Owns the ride lifecycle (RULE-1/RULE-2 in milestone 7's rules.md): which ride is active, the
/// locks that stop Start/Resume/Demo and Finish from running twice, and cancelling a ride's
/// background tasks. Moved out of `AppRouter` so that navigation can never stop a ride — only
/// `activate(_:)` (replacing a ride) and `end(_:)` cancel tasks.
@MainActor
@Observable
final class RideCoordinator {
    enum Phase: Equatable {
        case idle
        case preparing
        case resuming
        case active
        case finishing
    }

    private(set) var activeRide: LiveRide?
    private(set) var phase: Phase = .idle
    private(set) var presentation: RidePresentation?

    private var preparingRide = false
    private var finishingRide = false

    /// Acquired synchronously before Start/Resume/Demo's first await. All three paths share this
    /// coordinator, so rapid taps and a launch-time resume cannot start two loops, and neither a
    /// start nor a resume can displace a ride that is already active.
    func beginPreparingRide(resuming: Bool = false) -> Bool {
        guard !preparingRide, activeRide == nil else { return false }
        preparingRide = true
        phase = resuming ? .resuming : .preparing
        return true
    }

    func endPreparingRide() {
        preparingRide = false
        if activeRide == nil, phase == .preparing || phase == .resuming {
            phase = .idle
        }
    }

    /// Makes `ride` the active ride and shows it. Re-activating the same tracker is a no-op apart
    /// from updating the stored value; activating a different ride cancels the old one's tasks.
    func activate(_ ride: LiveRide) {
        if let current = activeRide, current.tracker !== ride.tracker {
            current.trackingTask.cancel()
            current.sessionTask.cancel()
        }
        activeRide = ride
        phase = .active
        presentation = .live(ride)
    }

    /// Acquired synchronously before Finish's first await, so a double tap (each tap spawns its
    /// own `Task`) cannot finalize and upload the same ride twice.
    func beginFinishingRide() -> Bool {
        guard !finishingRide else { return false }
        finishingRide = true
        if activeRide != nil {
            phase = .finishing
        }
        return true
    }

    func endFinishingRide() {
        finishingRide = false
        if phase == .finishing {
            phase = activeRide == nil ? .idle : .active
        }
    }

    /// Stops `ride`'s tracking and advisor loop and clears it as the active ride. Called before the
    /// ride is finalized, so no further checkpoint can overwrite the final record. The cover keeps
    /// showing the ride until `presentSummary(_:)`.
    func end(_ ride: LiveRide) {
        ride.trackingTask.cancel()
        ride.sessionTask.cancel()
        guard activeRide?.tracker === ride.tracker else { return }
        activeRide = nil
        phase = finishingRide ? .finishing : .idle
    }

    /// Switches the cover to the finished ride's summary.
    func presentSummary(_ outcome: FinishOutcome) {
        presentation = .summary(outcome)
    }

    /// The summary's Done: closes the cover.
    func dismissSummary() {
        guard case .summary = presentation else { return }
        presentation = nil
    }
}

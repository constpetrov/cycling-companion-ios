import Foundation
import RoutePersistence

/// Display-ready state for the ride summary (RULE-9/RULE-22 in milestone 7's rules.md, AC-77 to
/// AC-84): the finished ride's figures and its upload status.
@MainActor
@Observable
final class RideSummaryViewModel {
    let outcome: FinishOutcome
    private let uploader: RideUploader
    private let decisionLog: DecisionLog
    private let locale: Locale

    init(outcome: FinishOutcome, uploader: RideUploader, decisionLog: DecisionLog, locale: Locale = .current) {
        self.outcome = outcome
        self.uploader = uploader
        self.decisionLog = decisionLog
        self.locale = locale
    }

    var savedRide: PersistedRide? {
        if case .saved(let ride) = outcome { return ride }
        return nil
    }

    /// AC-84.
    var notSavedMessage: String? {
        savedRide == nil ? "Couldn't save this ride — it will resume next time you open the app" : nil
    }

    // MARK: - Figures (AC-78)

    var distanceText: String? {
        savedRide.map { LiveRideViewModel.distanceText(meters: $0.totalDistanceMeters, locale: locale) }
    }

    var movingTimeText: String? {
        savedRide.map {
            Duration.seconds(Int($0.totalMovingTimeSeconds))
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(locale))
        }
    }

    var averageSpeedText: String? {
        guard let ride = savedRide, ride.totalMovingTimeSeconds > 0 else { return nil }
        return LiveRideViewModel.speedText(
            metersPerSecond: ride.totalDistanceMeters / ride.totalMovingTimeSeconds, locale: locale)
    }

    /// Stops the rider made at suggested places, inferred from the track as for the upload.
    var stopsTaken: Int? {
        savedRide.map {
            RideOutcomeCalculator.stopsTaken(postedNotifications: decisionLog.postedNotifications, track: $0.track)
        }
    }

    /// Suggestion answers recorded this ride. Answers arrive with task-4.x; until then every
    /// ride has none.
    var suggestionsText: String {
        "No stop suggestions answered"
    }

    // MARK: - Upload (AC-79 to AC-83)

    var uploadStatusText: String? {
        guard savedRide != nil else { return nil }
        switch uploader.status {
        case .uploading, nil: return "Uploading…"
        case .saved: return "Saved"
        case .queued: return "Queued — will retry"
        }
    }

    var showsRetryNow: Bool {
        savedRide != nil && uploader.status == .queued
    }

    func retryNow() async {
        await uploader.retryNow()
    }
}

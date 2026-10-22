import Foundation

/// Display-ready state for the live ride dashboard (RULE-9/RULE-10/RULE-12 in milestone 7's
/// rules.md). Reads `RideTracker` and turns it into locale-formatted text and badge flags, so the
/// view only lays things out.
@MainActor
@Observable
final class LiveRideViewModel {
    /// AC-31 to AC-33: no fix for this long (or none yet) shows the no-GPS badge.
    static let gpsLostAfterSeconds: TimeInterval = 30
    /// How often the no-GPS badge is re-evaluated while the dashboard is visible.
    static let gpsCheckIntervalSeconds: TimeInterval = 1

    let tracker: RideTracker
    private let clock: Clock
    private let locale: Locale
    private let timeZone: TimeZone

    /// AC-30 to AC-33: `true` before the first fix and once `gpsLostAfterSeconds` have passed
    /// without one. Updated by `refreshGPSState()`.
    private(set) var isGPSLost = true
    /// Ride-clock time of the latest GPS check, used to turn the ETA into an arrival time.
    private(set) var now: Date?

    init(tracker: RideTracker, clock: Clock, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.tracker = tracker
        self.clock = clock
        self.locale = locale
        self.timeZone = timeZone
    }

    // MARK: - Metrics

    var distanceRemainingMeters: Double {
        max(tracker.totalRouteDistanceMeters - tracker.distanceAlongRouteMeters, 0)
    }

    /// AC-20/AC-29: distance remaining along the route. Off route, the tracker doesn't advance, so
    /// this keeps the last on-route value rather than going blank.
    var distanceRemainingText: String {
        Self.distanceText(meters: distanceRemainingMeters, locale: locale)
    }

    /// AC-21: the ETA as a clock time of day, or `nil` while there is no ETA yet.
    var arrivalTimeText: String? {
        guard let etaSeconds = tracker.etaSeconds, let now else { return nil }
        let arrival = now.addingTimeInterval(etaSeconds)
        return arrival.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// AC-22: current speed, or `nil` before a fix with speed exists.
    var speedText: String? {
        guard let metersPerSecond = tracker.latestFix?.speedMetersPerSecond, metersPerSecond >= 0 else { return nil }
        return Self.speedText(metersPerSecond: metersPerSecond, locale: locale)
    }

    // MARK: - Badges

    /// AC-26 to AC-28: off route only strictly beyond the shared corridor tolerance (a fix at
    /// exactly 50 m is still on route).
    var isOffRoute: Bool {
        Self.isOffRoute(offRouteMeters: tracker.latestOffRouteMeters)
    }

    nonisolated static func isOffRoute(offRouteMeters: Double?) -> Bool {
        guard let offRouteMeters else { return false }
        return offRouteMeters > RideTracker.corridorToleranceMeters
    }

    /// Re-evaluates the no-GPS badge against `clock`.
    func refreshGPSState() async {
        let current = await clock.now
        now = current
        guard let lastFixAt = tracker.lastFixAt else {
            isGPSLost = true
            return
        }
        isGPSLost = current.timeIntervalSince(lastFixAt) >= Self.gpsLostAfterSeconds
    }

    /// Keeps the no-GPS badge and arrival time current while the dashboard is visible; run from
    /// the view's `.task`, which cancels it when the dashboard goes away.
    func monitorGPS() async {
        while !Task.isCancelled {
            await refreshGPSState()
            do {
                try await clock.sleep(for: Self.gpsCheckIntervalSeconds)
            } catch {
                return
            }
        }
    }

    // MARK: - Formatting (RULE-10)

    /// Road distances in the locale's system: km/m for metric, mi/ft for US and UK.
    nonisolated static func distanceText(meters: Double, locale: Locale) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
    }

    /// Speed in km/h for metric locales and mph for US and UK. `.road` isn't a usage for speed, so
    /// the unit is chosen from the locale's measurement system.
    nonisolated static func speedText(metersPerSecond: Double, locale: Locale) -> String {
        let unit: UnitSpeed = locale.measurementSystem == .metric ? .kilometersPerHour : .milesPerHour
        return Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
            .converted(to: unit)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(1))
                ).locale(locale))
    }
}

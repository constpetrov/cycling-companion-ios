import CoreLocation
import Foundation
import RoutePersistence

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
    private let keepScreenOnPreference: KeepScreenOnPreference
    private let idleTimer: IdleTimerControlling
    private let session: RideSession?
    private let directions: DirectionsOpening
    private var isDashboardVisible = false

    /// The ride's suggestion state as last read from `RideSession` (RULE-15/RULE-16).
    private(set) var ledger = SuggestionLedger()
    /// The stop sheet, when open (AC-49, AC-71).
    var stopSheet: StopSheetItem?

    /// AC-37/AC-38: the rider's keep-screen-on choice, starting from the remembered value.
    private(set) var keepScreenOn: Bool

    /// AC-30 to AC-33: `true` before the first fix and once `gpsLostAfterSeconds` have passed
    /// without one. Updated by `refreshGPSState()`.
    private(set) var isGPSLost = true
    /// Ride-clock time of the latest GPS check, used to turn the ETA into an arrival time.
    private(set) var now: Date?

    /// The ride's route and corridor stops, loaded once from `RouteStore` for the map.
    private(set) var route: PersistedRoute?
    /// AC-17/AC-18: whether the map camera follows the rider. Panning turns it off; Recenter
    /// turns it back on.
    private(set) var isFollowingRider = true
    /// Where the map camera should be centred while following. Moved by the 1 s GPS check only once
    /// the rider has gone `cameraFollowStepMeters` (and by Recenter): at the follow zoom a smaller
    /// move is barely visible, and every move redraws the map.
    private(set) var cameraCenter: CLLocationCoordinate2D?
    static let cameraFollowStepMeters: Double = 50
    /// Where the map draws the rider. Reading it rebuilds the map's content, route line included, so
    /// it's moved by the 1 s GPS check once the rider has gone `riderMarkerStepMeters`, not on every fix.
    private(set) var mapRiderCoordinate: CLLocationCoordinate2D?
    static let riderMarkerStepMeters: Double = 10

    init(
        tracker: RideTracker, clock: Clock? = nil, locale: Locale = .current, timeZone: TimeZone = .current,
        keepScreenOnPreference: KeepScreenOnPreference = InMemoryKeepScreenOnPreference(),
        idleTimer: IdleTimerControlling = NoIdleTimer(), session: RideSession? = nil,
        directions: DirectionsOpening = NoDirections(), stopTypeFilter: StopTypeFilter = .allEnabled
    ) {
        self.stopTypeFilter = stopTypeFilter
        self.tracker = tracker
        self.clock = clock ?? tracker.clock
        self.locale = locale
        self.timeZone = timeZone
        self.keepScreenOnPreference = keepScreenOnPreference
        self.idleTimer = idleTimer
        self.session = session
        self.directions = directions
        self.keepScreenOn = keepScreenOnPreference.isEnabled
    }

    // MARK: - Suggestions (RULE-15/RULE-16, AC-45 to AC-57)

    /// The suggestion on the card, if any.
    var currentSuggestion: ApprovedSuggestion? { ledger.current }

    /// AC-54: the card's "heading to" state.
    var isHeadingToCurrent: Bool { ledger.isCurrentAccepted }

    /// AC-48: the suggested stop's pin is highlighted.
    var highlightedStopId: Int64? { ledger.current?.stopId }

    /// AC-47: how far along the route the stop is from here.
    func distanceAheadText(for suggestion: ApprovedSuggestion) -> String {
        Self.distanceText(meters: max(suggestion.kmMarkMeters - tracker.distanceAlongRouteMeters, 0), locale: locale)
    }

    func detourText(for suggestion: ApprovedSuggestion) -> String {
        Self.distanceText(meters: suggestion.detourMeters, locale: locale)
    }

    /// Listens for Guardrail-approved suggestions for as long as the dashboard is visible.
    func listenForSuggestions() async {
        guard let session else { return }
        await refreshLedger()
        for await _ in session.approvedSuggestions {
            await refreshLedger()
        }
    }

    func refreshLedger() async {
        guard let session else { return }
        ledger = await session.suggestionLedger()
    }

    /// AC-49: tapping the card opens the sheet for its suggestion.
    func openSheetForCurrentSuggestion() {
        guard let current = ledger.current else { return }
        stopSheet = StopSheetItem(suggestion: current, offersAnswers: true)
    }

    /// AC-71 to AC-73: a sheet for a stop from a notification. A stop suggested earlier this ride
    /// gets the answers for that suggestion; a stop never suggested gets Directions only.
    func openSheet(forStop stop: PersistedPoiInput) {
        if let earlier = ledger.suggestion(forStop: stop.osmId) {
            stopSheet = StopSheetItem(suggestion: earlier, offersAnswers: true)
        } else {
            let unsuggested = ApprovedSuggestion(
                id: "stop-\(stop.osmId)", stopId: stop.osmId, name: stop.name, type: stop.type,
                latitude: stop.latitude, longitude: stop.longitude, kmMarkMeters: stop.kmMarkMeters,
                detourMeters: stop.detourMeters, message: nil, suggestedAt: now ?? Date())
            stopSheet = StopSheetItem(suggestion: unsuggested, offersAnswers: false)
        }
    }

    /// AC-71/AC-72: opens the sheet for a tapped notification's stop if the route has it; an
    /// unknown stop just leaves the dashboard showing.
    func open(_ link: StopLink, routeStore: RouteStore) async {
        // On a cold launch or resume the ledger isn't loaded yet; without it a suggested stop
        // would open without Accept / Decline.
        await refreshLedger()
        await loadRoute(from: routeStore)
        guard let stop = route?.pois.first(where: { $0.osmId == link.stopId }) else { return }
        openSheet(forStop: stop)
    }

    /// AC-50/AC-51: Apple Maps directions; counts as accepting an unanswered suggestion.
    func openDirections(for item: StopSheetItem) async {
        let suggestion = item.suggestion
        directions.openDirections(
            toLatitude: suggestion.latitude, longitude: suggestion.longitude,
            name: suggestion.name ?? Self.typeLabel(suggestion.type))
        guard item.offersAnswers, let session else { return }
        await session.directionsOpened(for: suggestion.id, at: await clock.now)
        await refreshLedger()
    }

    /// AC-53/AC-54.
    func accept(_ item: StopSheetItem) async {
        await answer(.accepted, item)
    }

    /// AC-55/AC-56: records the decline, closes the sheet, and the card goes.
    func decline(_ item: StopSheetItem) async {
        await answer(.declined, item)
        stopSheet = nil
    }

    private func answer(_ answer: SuggestionAnswer, _ item: StopSheetItem) async {
        guard item.offersAnswers, let session else { return }
        await session.respond(answer, to: item.suggestion.id, at: await clock.now)
        await refreshLedger()
    }

    /// A readable label for an unnamed stop's OSM-derived type, e.g. `CAFE_BAKERY_RESTAURANT`.
    nonisolated static func typeLabel(_ type: String) -> String {
        let words = type.split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return "Stop" }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    // MARK: - Keep screen on (RULE-13)

    /// AC-34/AC-35/AC-38: remembers the choice and applies it at once if the dashboard is showing.
    func setKeepScreenOn(_ enabled: Bool) {
        keepScreenOn = enabled
        keepScreenOnPreference.isEnabled = enabled
        applyIdleTimer()
    }

    func dashboardDidAppear() {
        isDashboardVisible = true
        applyIdleTimer()
    }

    /// AC-36: also called when the ride ends, so auto-lock is restored either way.
    func dashboardDidDisappear() {
        isDashboardVisible = false
        applyIdleTimer()
    }

    private func applyIdleTimer() {
        idleTimer.setIdleTimerDisabled(isDashboardVisible && keepScreenOn)
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

    // MARK: - Map (RULE-11)

    /// The rider's position from the ride's own latest fix — a replayed position in Demo Mode —
    /// never the device's location.
    var riderCoordinate: CLLocationCoordinate2D? {
        tracker.latestFix.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Built once when the route loads, not on every map redraw.
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []

    /// Every stop of the route (used for notification taps and the sheet).
    var stops: [PersistedPoiInput] {
        route?.pois ?? []
    }

    /// What the map draws: the 2 nearest stops of each type ahead of the rider, plus the suggested
    /// stop (milestone 8 review). Recomputed only when the rider has moved on by
    /// `visibleStopsStepMeters`, has passed a shown stop, or the suggestion changes — not every second.
    private(set) var visibleStops: [PersistedPoiInput] = []
    private var visibleStopsProgress = -Double.infinity
    private var visibleStopsHighlight: Int64?
    /// Stop types turned off in Settings aren't drawn (the suggested stop always is).
    private let stopTypeFilter: StopTypeFilter
    static let visibleStopsStepMeters: Double = 100

    func updateVisibleStops(force: Bool = false) {
        let progress = tracker.distanceAlongRouteMeters
        let passedAShownStop = visibleStops.contains { $0.kmMarkMeters < progress && $0.osmId != highlightedStopId }
        guard force || passedAShownStop || highlightedStopId != visibleStopsHighlight
            || progress - visibleStopsProgress >= Self.visibleStopsStepMeters
        else { return }
        visibleStops = MapStopSelection.nearestAhead(
            stopTypeFilter.apply(stops), from: progress, alwaysInclude: highlightedStopId)
        visibleStopsProgress = progress
        visibleStopsHighlight = highlightedStopId
    }

    /// AC-132: a stop as VoiceOver reads it — name and how far ahead (or behind).
    func stopAccessibilityLabel(_ stop: PersistedPoiInput) -> String {
        let name = stop.name ?? Self.typeLabel(stop.type)
        let ahead = stop.kmMarkMeters - tracker.distanceAlongRouteMeters
        let distance = Self.distanceText(meters: abs(ahead), locale: locale)
        return ahead >= 0 ? "\(name), \(distance) ahead" : "\(name), passed"
    }

    func loadRoute(from routeStore: RouteStore) async {
        guard route == nil else { return }
        route = try? await routeStore.fetch(routeId: tracker.routeId)
        routeCoordinates = route?.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? []
        updateVisibleStops(force: true)
    }

    /// AC-18: the rider moved the map themselves.
    func riderDidPan() {
        isFollowingRider = false
    }

    /// AC-19: centre on the rider again and keep following.
    func recenter() {
        isFollowingRider = true
        cameraCenter = riderCoordinate
        mapRiderCoordinate = riderCoordinate
    }

    /// Whether `coordinate` has moved at least `meters` from `current`; a first position always has.
    nonisolated static func hasMoved(
        from current: CLLocationCoordinate2D?, to coordinate: CLLocationCoordinate2D, atLeast meters: Double
    ) -> Bool {
        guard let current else { return true }
        return GeoMath.haversineDistanceMeters(
            TrackPoint(latitude: current.latitude, longitude: current.longitude, elevationMeters: nil),
            TrackPoint(latitude: coordinate.latitude, longitude: coordinate.longitude, elevationMeters: nil)) >= meters
    }

    /// AC-25: heart rate and cadence aren't shown on the dashboard this milestone — real rides have
    /// no sensors (`NoSensorSource`), and Demo Mode's replayed values are deliberately hidden too
    /// (spec decision 7), so the screen never advertises metrics a rider can't have.
    var showsSensorFields: Bool { false }

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
        if let riderCoordinate {
            if Self.hasMoved(from: mapRiderCoordinate, to: riderCoordinate, atLeast: Self.riderMarkerStepMeters) {
                mapRiderCoordinate = riderCoordinate
            }
            if isFollowingRider,
                Self.hasMoved(from: cameraCenter, to: riderCoordinate, atLeast: Self.cameraFollowStepMeters)
            {
                cameraCenter = riderCoordinate
            }
        }
        // The session advances the ledger as the rider passes a stop; pick that up here.
        await refreshLedger()
        updateVisibleStops()
        guard let lastFixAt = tracker.lastFixAt else {
            isGPSLost = true
            return
        }
        isGPSLost = current.timeIntervalSince(lastFixAt) >= Self.gpsLostAfterSeconds
    }

    /// Keeps the no-GPS badge and arrival time current while the dashboard is visible; run from
    /// the view's `.task`, which cancels it when the dashboard goes away or the phone locks.
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

/// What the stop sheet shows: a stop, and whether Accept/Decline apply (they don't for a stop that
/// was never suggested this ride — AC-73).
struct StopSheetItem: Identifiable, Equatable {
    let suggestion: ApprovedSuggestion
    let offersAnswers: Bool

    var id: String { suggestion.id }
}

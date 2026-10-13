import Foundation
import RoutePersistence

/// The live-ride orchestrator (RULE-1 in spec/rules.md, AC-12 through AC-15, AC-21/AC-22/
/// AC-24/AC-26) — the end-to-end driver tying Feature Engine, the Local Trigger/Local
/// Advisor/Guardrail Gate chain, and the Notifier together, which every advisor-chain
/// component built in Milestone 3 was deliberately left without.
///
/// Takes an already-constructed `RideTracker`/`FeatureEngine` pair (the caller resolves which
/// `LocationSource`/`SensorSource`/`Clock` back them — real sources for a live ride,
/// `DemoModeReplayDriver` substituted in for Demo Mode), mirroring `FeatureEngine`'s own
/// existing precedent of taking a pre-built `RideTracker` rather than raw sources itself.
actor RideSession {
    private let rideTracker: RideTracker
    private let featureEngine: FeatureEngine
    private let clock: Clock
    private let snapshotIntervalSeconds: TimeInterval
    private let pollGranularitySeconds: TimeInterval
    private let decisionLog: DecisionLog
    private let notifier: Notifier

    private let routeId: String
    private let routeStore: RouteStore

    private var secondsSinceLastCheck: TimeInterval = 0
    private var forceRequested = false
    /// RULE-5: time since `LocalTrigger.shouldProceed` last returned `true` — a separate
    /// counter from `secondsSinceLastCheck` (this milestone's snapshot *cadence*); this one is
    /// Local Advisor's own 45-minute fallback counter (RULE-20/AC-15/AC-16/AC-17, Milestone 3).
    private var lastAdvisorProceedTimestamp: Date?
    private var lastApprovedSuggestionTimestamp: Date?

    init(
        rideTracker: RideTracker, featureEngine: FeatureEngine, clock: Clock, routeId: String, routeStore: RouteStore,
        decisionLog: DecisionLog, notifier: Notifier, snapshotIntervalSeconds: TimeInterval = 60.0,
        pollGranularitySeconds: TimeInterval = 1.0
    ) {
        self.rideTracker = rideTracker
        self.featureEngine = featureEngine
        self.clock = clock
        self.routeId = routeId
        self.routeStore = routeStore
        self.decisionLog = decisionLog
        self.notifier = notifier
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
        self.pollGranularitySeconds = pollGranularitySeconds
    }

    /// One polling step: sleeps `pollGranularitySeconds`, then runs a cycle if the cadence has
    /// elapsed or a check was forced (`AdvisorCheckCadence.shouldCheckNow`). Exposed separately
    /// from `run()` so tests can call it a fixed number of times directly, mirroring
    /// `FeatureEngine.tick()` vs `run()` — the same reason, the same shape.
    @discardableResult
    func step() async throws -> Bool {
        try await clock.sleep(for: pollGranularitySeconds)
        secondsSinceLastCheck += pollGranularitySeconds

        guard
            AdvisorCheckCadence.shouldCheckNow(
                forceRequested: forceRequested, secondsSinceLastCheck: secondsSinceLastCheck,
                cadenceSeconds: snapshotIntervalSeconds)
        else {
            return false
        }
        forceRequested = false
        secondsSinceLastCheck = 0
        await runCycle()
        return true
    }

    /// The production entry point — runs `step()` for the duration of a ride. Never returns in
    /// production; tests call `step()` directly instead.
    func run() async throws {
        while true {
            try await step()
        }
    }

    #if DEBUG
    /// AC-24: the next `step()` call runs a cycle immediately, without waiting out the cadence.
    func forceNextCheck() {
        forceRequested = true
    }
    #endif

    /// RULE-1/RULE-4/RULE-5/RULE-6: computes a snapshot, evaluates the Local Trigger/Local
    /// Advisor/Guardrail Gate chain, and calls the Notifier for an approved verdict. Never
    /// throws and never lets a rejected verdict or a no-suggestion decision stop the loop —
    /// `Notifier.notify`'s own error is swallowed rather than propagated, consistent with that
    /// guarantee. A no-op if no location fix has arrived yet (no `track` sample to read "now"
    /// from).
    private func runCycle() async {
        let snapshot = await featureEngine.computeAndAppendSnapshot()
        let track = await rideTracker.track
        guard let now = track.last?.timestamp else {
            return
        }

        let currentKmMarkMeters = await rideTracker.distanceAlongRouteMeters
        let (etaDayOfWeek, etaMinuteOfDay) = Self.isoDayOfWeekAndMinuteOfDay(for: now)
        // AC-26: re-fetched every cycle, never cached — a `nil`/failed fetch (or a route still
        // `building` with no POIs yet) reads as zero candidates rather than throwing, so POIs
        // that finish building after the ride already started are picked up on the very next
        // cycle once CorridorImportCoordinator's second RouteStore write lands.
        let pois: [PersistedPoiInput]
        do {
            pois = try await routeStore.fetch(routeId: routeId)?.pois ?? []
        } catch {
            pois = []
        }
        let candidates = POILookahead.candidates(
            pois: pois, currentKmMarkMeters: currentKmMarkMeters, etaDayOfWeek: etaDayOfWeek,
            etaMinuteOfDay: etaMinuteOfDay)
        let hasQualifyingStopAhead = !candidates.isEmpty

        let rideStart = track.first?.timestamp ?? now
        let secondsSinceLastCheckThatProceeded = now.timeIntervalSince(lastAdvisorProceedTimestamp ?? rideStart)
        if LocalTrigger.shouldProceed(
            snapshot: snapshot, hasQualifyingStopAhead: hasQualifyingStopAhead,
            secondsSinceLastCheckThatProceeded: secondsSinceLastCheckThatProceeded)
        {
            lastAdvisorProceedTimestamp = now
        }

        let decision = LocalAdvisor.decide(
            snapshot: snapshot, candidates: candidates, hasQualifyingStopAhead: hasQualifyingStopAhead,
            secondsSinceLastCheckThatProceeded: secondsSinceLastCheckThatProceeded, log: decisionLog)

        let lastStopTimestamp = snapshot.timeSinceLastStopSeconds.map { now.addingTimeInterval(-$0) }
        let verdict = GuardrailGate.evaluate(
            decision: decision, candidates: candidates, now: now,
            lastApprovedSuggestionTimestamp: lastApprovedSuggestionTimestamp, lastStopTimestamp: lastStopTimestamp,
            log: decisionLog)
        if verdict.suggest {
            lastApprovedSuggestionTimestamp = now
        }

        try? await notifier.notify(verdict: verdict, candidates: candidates)
    }

    /// RULE-5: ISO-8601 day-of-week (1 = Monday...7 = Sunday) and minute-of-day, in the
    /// device's current calendar/time zone — the same "now" POI Lookahead's ETA parameters and
    /// Guardrail Gate's timestamps both read from, derived once per cycle, never from a second,
    /// independently-read live clock.
    private static func isoDayOfWeekAndMinuteOfDay(for date: Date) -> (dayOfWeek: Int, minuteOfDay: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday...7 = Saturday
        let isoDayOfWeek = weekday == 1 ? 7 : weekday - 1
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return (isoDayOfWeek, hour * 60 + minute)
    }
}

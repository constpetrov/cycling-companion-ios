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
    private let advisorClient: AdvisorClient?
    private let stopTypeFilter: StopTypeFilter

    private let routeId: String
    private let routeStore: RouteStore

    private var secondsSinceLastCheck: TimeInterval = 0
    private var forceRequested = false
    /// RULE-5: time since `LocalTrigger.shouldProceed` last returned `true` — a separate
    /// counter from `secondsSinceLastCheck` (this milestone's snapshot *cadence*); this one is
    /// Local Advisor's own 45-minute fallback counter (RULE-20/AC-15/AC-16/AC-17, Milestone 3).
    private var lastAdvisorProceedTimestamp: Date?
    private var lastApprovedSuggestionTimestamp: Date?

    /// This ride's suggestions, answers and declined stops (RULE-16 in milestone 7's rules.md).
    private var ledger = SuggestionLedger()
    /// Each Guardrail-approved suggestion, for the dashboard (RULE-15 in milestone 7's rules.md).
    nonisolated let approvedSuggestions: AsyncStream<ApprovedSuggestion>
    private let approvedSuggestionsContinuation: AsyncStream<ApprovedSuggestion>.Continuation

    init(
        rideTracker: RideTracker, featureEngine: FeatureEngine, clock: Clock, routeId: String, routeStore: RouteStore,
        decisionLog: DecisionLog, notifier: Notifier, snapshotIntervalSeconds: TimeInterval = 60.0,
        pollGranularitySeconds: TimeInterval = 1.0, advisorClient: AdvisorClient? = nil,
        stopTypeFilter: StopTypeFilter = .allEnabled
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
        self.advisorClient = advisorClient
        self.stopTypeFilter = stopTypeFilter
        (approvedSuggestions, approvedSuggestionsContinuation) = AsyncStream.makeStream(
            of: ApprovedSuggestion.self, bufferingPolicy: .bufferingNewest(1))
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

    // MARK: - Suggestions (RULE-16 in milestone 7's rules.md)

    func suggestionLedger() -> SuggestionLedger {
        ledger
    }

    /// Records the answer and checkpoints straight away, so it survives the app being killed.
    @discardableResult
    func respond(_ answer: SuggestionAnswer, to suggestionId: String, at time: Date) async -> Bool {
        let recorded = ledger.respond(answer, to: suggestionId, at: time)
        if recorded { await rideTracker.checkpointNow() }
        return recorded
    }

    func directionsOpened(for suggestionId: String, at time: Date) async {
        ledger.directionsOpened(for: suggestionId, at: time)
        await rideTracker.checkpointNow()
    }

    /// Restores the ledger saved with a ride checkpoint, after the app was killed mid-ride.
    func restoreLedger(_ restored: SuggestionLedger) {
        ledger = restored
    }

    /// The ride's full feature-snapshot timeline so far (RULE-16 in spec/rules.md, Milestone 6)
    /// — a thin forwarder so `RideFinisher` can read it for Ride Ingest without `featureEngine`
    /// itself ever leaking outside this actor.
    func featureSnapshots() async -> [FeatureSnapshot] {
        await featureEngine.snapshots
    }

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
        ledger.advance(toKmMark: currentKmMarkMeters)
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
        // AC-64/AC-65: a stop the rider declined this ride is never a candidate again, so neither
        // the trigger, the advisor nor the Guardrail Gate (which rejects non-candidates) can pick it.
        let declined = ledger.declinedStopIds
        // Stop types turned off in Settings are never candidates, so they can't be suggested.
        let candidates = POILookahead.candidates(
            pois: stopTypeFilter.apply(pois), currentKmMarkMeters: currentKmMarkMeters, etaDayOfWeek: etaDayOfWeek,
            etaMinuteOfDay: etaMinuteOfDay
        ).filter { !declined.contains($0.osmId) }
        let hasQualifyingStopAhead = !candidates.isEmpty

        let rideStart = track.first?.timestamp ?? now
        let secondsSinceLastCheckThatProceeded = now.timeIntervalSince(lastAdvisorProceedTimestamp ?? rideStart)
        let triggerProceeds = LocalTrigger.shouldProceed(
            snapshot: snapshot, hasQualifyingStopAhead: hasQualifyingStopAhead,
            secondsSinceLastCheckThatProceeded: secondsSinceLastCheckThatProceeded)
        if triggerProceeds {
            lastAdvisorProceedTimestamp = now
        }

        // RULE-12: the remote Advisor is attempted only when the trigger proceeds and there's
        // at least one candidate — LocalAdvisor.decide already short-circuits to "no
        // suggestion" on an empty candidate list, so attempting the remote call first would
        // spend it on an already-known outcome. RULE-15: a non-nil remote decision (including
        // a well-formed suggest:false) is used as-is, without also asking Local Advisor.
        var remoteDecision: AdvisorDecision?
        if triggerProceeds, !candidates.isEmpty, let advisorClient {
            remoteDecision = await advisorClient.requestDecision(
                rideId: rideTracker.rideId, routeId: routeId, snapshot: snapshot, candidates: candidates)
            if let remoteDecision {
                // RULE-16: exactly one decisionLog entry per cycle regardless of source —
                // LocalAdvisor.decide logs its own decision internally; this mirrors that for
                // the remote path rather than logging twice or not at all.
                decisionLog.recordAdvisorDecision(remoteDecision)
            }
        }
        let decision =
            remoteDecision
            ?? LocalAdvisor.decide(
                snapshot: snapshot, candidates: candidates, hasQualifyingStopAhead: hasQualifyingStopAhead,
                secondsSinceLastCheckThatProceeded: secondsSinceLastCheckThatProceeded, log: decisionLog)

        let lastStopTimestamp = snapshot.timeSinceLastStopSeconds.map { now.addingTimeInterval(-$0) }
        let verdict = GuardrailGate.evaluate(
            decision: decision, candidates: candidates, now: now,
            lastApprovedSuggestionTimestamp: lastApprovedSuggestionTimestamp, lastStopTimestamp: lastStopTimestamp,
            log: decisionLog)
        // AC-64/AC-65: the rider may have declined this stop while the advisor call was in flight.
        if let stopId = verdict.stopId, ledger.declinedStopIds.contains(where: { String($0) == stopId }) {
            return
        }
        if verdict.suggest {
            lastApprovedSuggestionTimestamp = now
            if let stopId = verdict.stopId, let stop = candidates.first(where: { String($0.osmId) == stopId }) {
                let suggestion = ApprovedSuggestion(
                    id: UUID().uuidString, stopId: stop.osmId, name: stop.name, type: stop.type,
                    latitude: stop.latitude, longitude: stop.longitude, kmMarkMeters: stop.kmMarkMeters,
                    detourMeters: stop.detourMeters, message: verdict.message, suggestedAt: now)
                ledger.approve(suggestion)
                approvedSuggestionsContinuation.yield(suggestion)
            }
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

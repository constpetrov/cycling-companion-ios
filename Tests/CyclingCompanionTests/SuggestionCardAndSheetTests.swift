import RoutePersistence
import XCTest

@testable import CyclingCompanion

@MainActor
private final class RecordingDirections: DirectionsOpening {
    private(set) var opened: [(latitude: Double, longitude: Double, name: String)] = []

    nonisolated init() {}

    func openDirections(toLatitude latitude: Double, longitude: Double, name: String) {
        opened.append((latitude, longitude, name))
    }
}

/// task-4.5 (RULE-9/RULE-16/RULE-19): AC-47 to AC-57, AC-73.
final class SuggestionCardAndSheetTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func suggestion(_ id: String = "a", stop: Int64 = 1, name: String? = "Café am Kanal") -> ApprovedSuggestion {
        ApprovedSuggestion(
            id: id, stopId: stop, name: name, type: "CAFE", latitude: 52.0125, longitude: 13.0015,
            kmMarkMeters: 1_400, detourMeters: 110, message: "Coffee?", suggestedAt: t0)
    }

    @MainActor
    private func viewModel(with ledger: SuggestionLedger, directions: DirectionsOpening = NoDirections()) async
        -> (LiveRideViewModel, RideSession)
    {
        let rideStore = RideStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let route = PersistedRoute(
            id: "route-1", hash: "h", totalDistanceMeters: 3_000, totalClimbingMeters: nil, status: "ready",
            points: [
                PersistedPointInput(latitude: 52, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 0),
                PersistedPointInput(latitude: 52.027, longitude: 13, elevationMeters: nil, cumulativeDistanceMeters: 3_000),
            ], pois: [])
        let log = DecisionLog()
        let (tracker, session) = await makeTrackerAndSession(
            rideId: "ride-1", routeId: "route-1", startTime: t0, route: route,
            locationSource: ReplayLocationSource(fixes: []), sensorSource: ReplaySensorSource(samples: []),
            clock: ReplayClock(start: t0), rideStore: rideStore, routeStore: routeStore, decisionLog: log,
            notifier: Notifier(scheduling: FakeNotificationScheduling(grantOnRequest: true), log: log))
        await session.restoreLedger(ledger)
        let viewModel = LiveRideViewModel(
            tracker: tracker, locale: Locale(identifier: "de_DE"), session: session, directions: directions)
        await viewModel.refreshLedger()
        return (viewModel, session)
    }

    private func ledger(with suggestion: ApprovedSuggestion) -> SuggestionLedger {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion)
        return ledger
    }

    // MARK: - Card (AC-47, AC-48)

    @MainActor
    func testTheCardShowsTheCurrentSuggestionAndItsPinIsHighlighted() async {
        let (viewModel, _) = await viewModel(with: ledger(with: suggestion()))

        XCTAssertEqual(viewModel.currentSuggestion?.name, "Café am Kanal")
        XCTAssertEqual(viewModel.highlightedStopId, 1)
        XCTAssertTrue(viewModel.distanceAheadText(for: suggestion()).contains("km"))
        XCTAssertTrue(viewModel.detourText(for: suggestion()).contains("110"))
    }

    func testAnUnnamedStopGetsAReadableTypeLabel() {
        XCTAssertEqual(LiveRideViewModel.typeLabel("CAFE_BAKERY_RESTAURANT"), "Cafe bakery restaurant")
        XCTAssertEqual(LiveRideViewModel.typeLabel("WATER"), "Water")
    }

    // MARK: - Sheet (AC-49, AC-57)

    @MainActor
    func testTappingTheCardOpensTheSheetWithAnswers() async {
        let (viewModel, _) = await viewModel(with: ledger(with: suggestion()))

        viewModel.openSheetForCurrentSuggestion()

        XCTAssertEqual(viewModel.stopSheet?.suggestion.id, "a")
        XCTAssertEqual(viewModel.stopSheet?.offersAnswers, true)
    }

    @MainActor
    func testSwipingTheSheetAwayRecordsNothingAndKeepsTheCard() async {
        let (viewModel, session) = await viewModel(with: ledger(with: suggestion()))
        viewModel.openSheetForCurrentSuggestion()

        viewModel.stopSheet = nil  // what the swipe-down does to the bound item

        let ledger = await session.suggestionLedger()
        XCTAssertNil(ledger.response(to: "a"))
        XCTAssertEqual(viewModel.currentSuggestion?.id, "a")
    }

    // MARK: - Directions (AC-50, AC-51)

    @MainActor
    func testDirectionsHandsTheStopToMapsAndCountsAsAccepting() async {
        let directions = RecordingDirections()
        let (viewModel, session) = await viewModel(with: ledger(with: suggestion()), directions: directions)
        viewModel.openSheetForCurrentSuggestion()

        await viewModel.openDirections(for: viewModel.stopSheet!)

        XCTAssertEqual(directions.opened.count, 1)
        XCTAssertEqual(directions.opened.first?.latitude, 52.0125)
        XCTAssertEqual(directions.opened.first?.name, "Café am Kanal")
        let ledger = await session.suggestionLedger()
        XCTAssertEqual(ledger.response(to: "a")?.answer, .accepted)
    }

    // MARK: - Accept / Decline (AC-53 to AC-56)

    @MainActor
    func testAcceptPutsTheCardInHeadingToState() async {
        let (viewModel, _) = await viewModel(with: ledger(with: suggestion()))
        viewModel.openSheetForCurrentSuggestion()

        await viewModel.accept(viewModel.stopSheet!)

        XCTAssertTrue(viewModel.isHeadingToCurrent)
        XCTAssertEqual(viewModel.currentSuggestion?.id, "a")
    }

    @MainActor
    func testDeclineClosesTheSheetAndRemovesTheCard() async {
        let (viewModel, session) = await viewModel(with: ledger(with: suggestion()))
        viewModel.openSheetForCurrentSuggestion()

        await viewModel.decline(viewModel.stopSheet!)

        XCTAssertNil(viewModel.stopSheet)
        XCTAssertNil(viewModel.currentSuggestion)
        let ledger = await session.suggestionLedger()
        XCTAssertEqual(ledger.declinedStopIds, [1])
    }

    // MARK: - Sheet from a notification (AC-73)

    @MainActor
    func testAStopNeverSuggestedThisRideOffersDirectionsOnly() async {
        let (viewModel, session) = await viewModel(with: SuggestionLedger())
        let stop = PersistedPoiInput(
            osmId: 7, type: "WATER", name: nil, latitude: 52.02, longitude: 13, kmMarkMeters: 2_200,
            detourMeters: 40, openingHours: nil)

        viewModel.openSheet(forStop: stop)
        await viewModel.accept(viewModel.stopSheet!)  // must be ignored

        XCTAssertEqual(viewModel.stopSheet?.offersAnswers, false)
        let ledger = await session.suggestionLedger()
        XCTAssertTrue(ledger.answers.isEmpty)
    }

    @MainActor
    func testAStopSuggestedEarlierThisRideGetsItsAnswers() async {
        var history = SuggestionLedger()
        history.approve(suggestion("a", stop: 1))
        history.approve(suggestion("b", stop: 2))
        let (viewModel, _) = await viewModel(with: history)
        let stop = PersistedPoiInput(
            osmId: 1, type: "CAFE", name: "Café am Kanal", latitude: 52.0125, longitude: 13.0015, kmMarkMeters: 1_400,
            detourMeters: 110, openingHours: nil)

        viewModel.openSheet(forStop: stop)

        XCTAssertEqual(viewModel.stopSheet?.suggestion.id, "a")
        XCTAssertEqual(viewModel.stopSheet?.offersAnswers, true)
    }

    // MARK: - From a notification (AC-71, AC-72)

    @MainActor
    func testALinkToAStopOnTheRouteOpensItsSheet() async throws {
        let (viewModel, _) = await viewModel(with: SuggestionLedger())
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 3_000, totalClimbingMeters: nil, points: [],
            pois: [
                PersistedPoiInput(
                    osmId: 1, type: "CAFE", name: "Café am Kanal", latitude: 52.0125, longitude: 13.0015,
                    kmMarkMeters: 1_400, detourMeters: 110, openingHours: nil)
            ], status: "ready")

        await viewModel.open(StopLink(stopId: 1), routeStore: routeStore)

        XCTAssertEqual(viewModel.stopSheet?.suggestion.stopId, 1)
    }

    @MainActor
    func testALinkToAnUnknownStopOpensNothing() async throws {
        let (viewModel, _) = await viewModel(with: SuggestionLedger())
        let routeStore = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await routeStore.persist(
            routeId: "route-1", hash: "h", totalDistanceMeters: 3_000, totalClimbingMeters: nil, points: [], pois: [],
            status: "ready")

        await viewModel.open(StopLink(stopId: 999), routeStore: routeStore)

        XCTAssertNil(viewModel.stopSheet)
    }
}

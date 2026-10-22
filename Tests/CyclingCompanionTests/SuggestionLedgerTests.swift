import XCTest

@testable import CyclingCompanion

/// task-4.2 (RULE-16): AC-51 to AC-63, AC-136, AC-137.
final class SuggestionLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func suggestion(_ id: String, stop: Int64, kmMark: Double = 5_000) -> ApprovedSuggestion {
        ApprovedSuggestion(
            id: id, stopId: stop, name: "Stop \(stop)", type: "CAFE", latitude: 52, longitude: 13,
            kmMarkMeters: kmMark, detourMeters: 100, message: "Coffee?", suggestedAt: t0)
    }

    func testApprovingShowsTheCard() {
        var ledger = SuggestionLedger()

        ledger.approve(suggestion("a", stop: 1))

        XCTAssertEqual(ledger.current?.id, "a")
        XCTAssertNil(ledger.response(to: "a"))
    }

    // MARK: - Directions (AC-51, AC-52)

    func testDirectionsAcceptsAnUnansweredSuggestion() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))

        ledger.directionsOpened(for: "a", at: t0 + 30)

        XCTAssertEqual(ledger.response(to: "a")?.answer, .accepted)
        XCTAssertEqual(ledger.response(to: "a")?.respondedAt, t0 + 30)
    }

    func testDirectionsKeepsAnExistingAnswer() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))
        ledger.respond(.accepted, to: "a", at: t0 + 10)

        ledger.directionsOpened(for: "a", at: t0 + 30)

        XCTAssertEqual(ledger.response(to: "a")?.respondedAt, t0 + 10)
    }

    // MARK: - Accept / Decline (AC-53 to AC-56, AC-64, AC-65)

    func testAcceptRecordsAndPutsTheCardInHeadingToState() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))

        ledger.respond(.accepted, to: "a", at: t0 + 5)

        XCTAssertEqual(ledger.response(to: "a")?.answer, .accepted)
        XCTAssertEqual(ledger.current?.id, "a")
        XCTAssertTrue(ledger.isCurrentAccepted)
    }

    func testDeclineRecordsRemovesTheCardAndExcludesTheStop() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))

        ledger.respond(.declined, to: "a", at: t0 + 5)

        XCTAssertEqual(ledger.response(to: "a")?.answer, .declined)
        XCTAssertNil(ledger.current)
        XCTAssertEqual(ledger.declinedStopIds, [1])
    }

    func testRespondingToAnUnknownSuggestionDoesNothing() {
        var ledger = SuggestionLedger()

        XCTAssertFalse(ledger.respond(.accepted, to: "nope", at: t0))
        XCTAssertTrue(ledger.answers.isEmpty)
    }

    // MARK: - Superseded (AC-58, AC-59)

    func testANewSuggestionMakesAnUnansweredOneNone() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))

        ledger.approve(suggestion("b", stop: 2))

        XCTAssertEqual(ledger.response(to: "a")?.answer, SuggestionAnswer.none)
        XCTAssertNil(ledger.response(to: "a")?.respondedAt)
        XCTAssertEqual(ledger.current?.id, "b")
    }

    func testANewSuggestionKeepsAnAcceptedOneAccepted() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))
        ledger.respond(.accepted, to: "a", at: t0 + 5)

        ledger.approve(suggestion("b", stop: 2))

        XCTAssertEqual(ledger.response(to: "a")?.answer, .accepted)
        XCTAssertEqual(ledger.current?.id, "b")
    }

    // MARK: - Passed at 200 m (AC-60 to AC-63)

    func testPassBoundaryAtTwoHundredMetres() {
        for (beyond, removed) in [(199.0, false), (200.0, true), (250.0, true)] {
            var ledger = SuggestionLedger()
            ledger.approve(suggestion("a", stop: 1, kmMark: 5_000))

            ledger.advance(toKmMark: 5_000 + beyond)

            XCTAssertEqual(ledger.current == nil, removed, "\(beyond) m beyond the stop")
            XCTAssertEqual(ledger.response(to: "a")?.answer, removed ? SuggestionAnswer.none : nil)
        }
    }

    func testAnAcceptedStopPassedKeepsItsAnswer() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1, kmMark: 5_000))
        ledger.respond(.accepted, to: "a", at: t0 + 5)

        ledger.advance(toKmMark: 5_200)

        XCTAssertNil(ledger.current)
        XCTAssertEqual(ledger.response(to: "a")?.answer, .accepted)
    }

    func testRidingBeforeTheStopKeepsTheCard() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1, kmMark: 5_000))

        ledger.advance(toKmMark: 3_000)

        XCTAssertEqual(ledger.current?.id, "a")
    }

    // MARK: - Late answers (AC-136, AC-137)

    func testALateAnswerReplacesNoneAndLeavesTheNewCardAlone() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))
        ledger.approve(suggestion("b", stop: 2))  // "a" becomes none while its sheet is still open

        ledger.respond(.declined, to: "a", at: t0 + 60)

        XCTAssertEqual(ledger.response(to: "a")?.answer, .declined)
        XCTAssertEqual(ledger.current?.id, "b", "the new card is unaffected")
        XCTAssertEqual(ledger.declinedStopIds, [1])
    }

    func testAnAnswerFromAnOlderNotificationReplacesTheEarlierResponse() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1, kmMark: 5_000))
        ledger.advance(toKmMark: 5_300)  // passed → none
        let earlier = ledger.suggestion(forStop: 1)

        ledger.respond(.accepted, to: earlier!.id, at: t0 + 120)

        XCTAssertEqual(ledger.response(to: "a")?.answer, .accepted)
        XCTAssertEqual(ledger.response(to: "a")?.respondedAt, t0 + 120)
    }

    // MARK: - Upload view (AC-67)

    func testFinalResponsesCoverEverySuggestionWithNoneForUnanswered() {
        var ledger = SuggestionLedger()
        ledger.approve(suggestion("a", stop: 1))
        ledger.respond(.accepted, to: "a", at: t0 + 5)
        ledger.approve(suggestion("b", stop: 2))

        let final = ledger.finalResponses

        XCTAssertEqual(final.map(\.suggestionId), ["a", "b"])
        XCTAssertEqual(final.map(\.answer), [.accepted, SuggestionAnswer.none])
    }

    func testWireValuesAreUppercase() {
        XCTAssertEqual(SuggestionAnswer.accepted.rawValue, "ACCEPTED")
        XCTAssertEqual(SuggestionAnswer.declined.rawValue, "DECLINED")
        XCTAssertEqual(SuggestionAnswer.none.rawValue, "NONE")
    }
}

import XCTest

@testable import CyclingCompanion

final class AdvisorCallScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func schedule(calledWith feature: FatigueFeature? = nil) -> AdvisorCallSchedule {
        var schedule = AdvisorCallSchedule()
        schedule.recordCall(crossedFeature: feature, at: start)
        return schedule
    }

    func testTheFirstCheckIsDue() {
        XCTAssertTrue(AdvisorCallSchedule().isDue(crossedFeature: nil, now: start))
    }

    func testNotDueBeforeTheRecheckInterval() {
        let now = start.addingTimeInterval(AdvisorCallSchedule.recheckIntervalSeconds - 1)
        XCTAssertFalse(schedule().isDue(crossedFeature: nil, now: now))
    }

    func testDueAtTheRecheckInterval() {
        let now = start.addingTimeInterval(AdvisorCallSchedule.recheckIntervalSeconds)
        XCTAssertTrue(schedule().isDue(crossedFeature: nil, now: now))
    }

    func testANewFatigueSignalIsDueStraightAway() {
        XCTAssertTrue(schedule().isDue(crossedFeature: .speedTrend, now: start.addingTimeInterval(60)))
        XCTAssertTrue(schedule(calledWith: .speedTrend).isDue(crossedFeature: .hrDrift, now: start.addingTimeInterval(60)))
    }

    func testASignalFlippingOffAndBackOnIsNotDueAgain() {
        let schedule = schedule(calledWith: .speedTrend)
        XCTAssertFalse(schedule.isDue(crossedFeature: nil, now: start.addingTimeInterval(60)))
        XCTAssertFalse(schedule.isDue(crossedFeature: .speedTrend, now: start.addingTimeInterval(120)))
    }
}

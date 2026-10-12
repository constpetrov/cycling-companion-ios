import XCTest

@testable import CyclingCompanion

/// task-2.1 validation (RULE-4/RULE-5 in spec/rules.md, AC-2/AC-3/AC-4/AC-5): a freshly
/// constructed snapshot has the four permanently-missing features nil by default — there's no
/// way to pass them a value without naming the parameter explicitly, which nothing in
/// FeatureEngine (task-2.2 onward) ever does.
final class FeatureSnapshotTests: XCTestCase {

    func testFreshSnapshotHasTheFourPermanentlyMissingFeaturesNil() {
        let snapshot = FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0))

        XCTAssertNil(snapshot.speedVsBaseline)
        XCTAssertNil(snapshot.workDone)
        XCTAssertNil(snapshot.rideSoFarVsLongest)
        XCTAssertNil(snapshot.conditions)
    }
}

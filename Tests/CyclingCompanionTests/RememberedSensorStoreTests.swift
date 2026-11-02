import XCTest

@testable import CyclingCompanion

/// Milestone 12 task-2.2: AC-1, AC-2, AC-5 to AC-8.
@MainActor
final class RememberedSensorStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RememberedSensorStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let strap = DiscoveredDevice(identifier: UUID(), name: "HRM-Pro", kinds: [.heartRate])
    private let secondStrap = DiscoveredDevice(identifier: UUID(), name: "Polar H10", kinds: [.heartRate])
    private let combined = DiscoveredDevice(identifier: UUID(), name: nil, kinds: [.heartRate, .cadence])

    func testStartsEmpty() {
        XCTAssertTrue(RememberedSensorStore(defaults: defaults).isEmpty)
    }

    /// AC-5.
    func testRememberingADeviceAddsOneEntryPerKind() {
        let store = RememberedSensorStore(defaults: defaults)
        store.remember(combined)
        XCTAssertEqual(Set(store.sensors.map(\.kind)), [.heartRate, .cadence])
        XCTAssertEqual(store.kinds(for: combined.identifier), [.heartRate, .cadence])
    }

    func testRememberingTheSameDeviceTwiceAddsNothing() {
        let store = RememberedSensorStore(defaults: defaults)
        store.remember(strap)
        store.remember(strap)
        XCTAssertEqual(store.sensors.count, 1)
    }

    /// AC-8.
    func testSeveralSensorsOfOneKindAreKept() {
        let store = RememberedSensorStore(defaults: defaults)
        store.remember(strap)
        store.remember(secondStrap)
        XCTAssertEqual(store.identifiers(for: .heartRate), [strap.identifier, secondStrap.identifier])
        XCTAssertFalse(store.hasKind(.cadence))
    }

    /// AC-6.
    func testRememberedSensorsSurviveARelaunch() {
        RememberedSensorStore(defaults: defaults).remember(strap)
        let relaunched = RememberedSensorStore(defaults: defaults)
        XCTAssertEqual(relaunched.sensors, [RememberedSensor(identifier: strap.identifier, name: "HRM-Pro", kind: .heartRate)])
    }

    /// AC-7.
    func testForgettingRemovesTheSensorForGood() throws {
        let store = RememberedSensorStore(defaults: defaults)
        store.remember(strap)
        store.remember(secondStrap)
        store.forget(try XCTUnwrap(store.sensors.first))
        XCTAssertEqual(store.identifiers(for: .heartRate), [secondStrap.identifier])
        XCTAssertEqual(RememberedSensorStore(defaults: defaults).identifiers(for: .heartRate), [secondStrap.identifier])
    }

    /// AC-1, AC-2.
    func testDisplayNameFallsBackToTheKind() {
        let store = RememberedSensorStore(defaults: defaults)
        store.remember(combined)
        XCTAssertEqual(Set(store.sensors.map(\.displayName)), ["Heart rate sensor", "Cadence sensor"])
    }
}

import XCTest

@testable import CyclingCompanion

/// Milestone 12 task-2.3 and task-2.4: one test per hub transition (RULE-17), AC-10, AC-12,
/// AC-16 to AC-21, AC-24, AC-26, AC-36.
@MainActor
final class SensorHubTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: RememberedSensorStore!
    private var clock: ManualClock!
    private var central: FakeBluetoothCentral!
    private var centralsCreated = 0
    private var hub: SensorHub!

    private let strapA = DiscoveredDevice(identifier: UUID(), name: "Strap A", kinds: [.heartRate])
    private let strapB = DiscoveredDevice(identifier: UUID(), name: "Strap B", kinds: [.heartRate])
    private let cadenceSensor = DiscoveredDevice(identifier: UUID(), name: "Cadence", kinds: [.cadence])
    private let combined = DiscoveredDevice(identifier: UUID(), name: "Combo", kinds: [.heartRate, .cadence])

    override func setUp() async throws {
        suiteName = "SensorHubTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = RememberedSensorStore(defaults: defaults)
        clock = ManualClock()
        central = FakeBluetoothCentral()
        centralsCreated = 0
        hub = SensorHub(store: store, clock: clock) { [unowned self] in
            centralsCreated += 1
            return central
        }
    }

    override func tearDown() async throws {
        hub.release(.ride)
        hub.release(.screen)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func heartRate(_ bpm: UInt8) -> Data { Data([0x00, bpm]) }

    private func crank(_ revolutions: UInt16, _ eventTime: UInt16) -> Data {
        Data([0x02, UInt8(revolutions & 0xFF), UInt8(revolutions >> 8), UInt8(eventTime & 0xFF), UInt8(eventTime >> 8)])
    }

    // MARK: - Creating the central

    /// AC-12, RULE-3: nothing touches Bluetooth until a holder or a scan asks.
    func testTheCentralIsNotCreatedUntilNeeded() {
        store.remember(strapA)
        XCTAssertEqual(centralsCreated, 0)
        hub.acquire(.ride)
        XCTAssertEqual(centralsCreated, 1)
    }

    // MARK: - Ride: first found, then stick

    /// AC-16, RULE-4: a ride asks for every remembered sensor and never scans.
    func testARideConnectsToAllRememberedSensorsWithoutScanning() {
        store.remember(strapA)
        store.remember(strapB)
        hub.acquire(.ride)
        XCTAssertEqual(central.pendingConnects, [strapA.identifier, strapB.identifier])
        XCTAssertEqual(central.scanStarts, 0)
    }

    /// AC-16, AC-17: the first to connect is used; the other's request is cancelled and its readings ignored.
    func testTheFirstSensorOfAKindToConnectIsUsedAndTheOtherIsDropped() async {
        store.remember(strapA)
        store.remember(strapB)
        hub.acquire(.ride)
        await central.emit(.connected(strapB.identifier))
        XCTAssertEqual(hub.assigned[.heartRate], strapB.identifier)
        XCTAssertEqual(central.cancelCalls, [strapA.identifier])

        await central.emit(.heartRateMeasurement(strapB.identifier, heartRate(141)))
        await central.emit(.heartRateMeasurement(strapA.identifier, heartRate(99)))
        XCTAssertEqual(hub.rideReading.heartRateBPM, 141)
    }

    /// AC-18, AC-19: a drop clears the reading at once and every remembered sensor of that kind is asked for again.
    func testADropClearsTheReadingAndReconnectsToAnyRememberedSensor() async {
        store.remember(strapA)
        store.remember(strapB)
        hub.acquire(.ride)
        await central.emit(.connected(strapA.identifier))
        await central.emit(.heartRateMeasurement(strapA.identifier, heartRate(150)))

        await central.emit(.disconnected(strapA.identifier))
        XCTAssertNil(hub.rideReading.heartRateBPM)
        XCTAssertEqual(central.pendingConnects, [strapA.identifier, strapB.identifier])

        await central.emit(.connected(strapB.identifier))
        await central.emit(.heartRateMeasurement(strapB.identifier, heartRate(152)))
        XCTAssertEqual(hub.rideReading.heartRateBPM, 152)
    }

    /// AC-20: with nothing in range, requests stay pending (CoreBluetooth never times them out) and nothing is retried by scanning.
    func testWithNothingInRangeRequestsStayPending() async {
        store.remember(strapA)
        hub.acquire(.ride)
        await clock.advance(by: 3_600)
        await hub.checkCoasting()
        XCTAssertEqual(central.pendingConnects, [strapA.identifier])
        XCTAssertEqual(central.cancelCalls, [])
        XCTAssertEqual(central.scanStarts, 0)
    }

    /// AC-21, RULE-10: a sensor forgotten mid-ride is not asked for again after it drops.
    func testAForgottenSensorIsNotReconnected() async throws {
        store.remember(strapA)
        hub.acquire(.ride)
        await central.emit(.connected(strapA.identifier))
        store.forget(try XCTUnwrap(store.sensors.first))
        await central.emit(.disconnected(strapA.identifier))
        XCTAssertEqual(central.pendingConnects, [])
    }

    /// AC-24, RULE-5: Bluetooth off clears everything; back on, the remembered sensors are asked for again.
    func testBluetoothOffAndOnAgain() async {
        store.remember(strapA)
        hub.acquire(.ride)
        await central.emit(.connected(strapA.identifier))
        await central.emit(.heartRateMeasurement(strapA.identifier, heartRate(130)))

        await central.emit(.availabilityChanged(.poweredOff))
        XCTAssertNil(hub.rideReading.heartRateBPM)
        XCTAssertEqual(hub.availability, .poweredOff)

        let connectsBefore = central.connectCalls.count
        await central.emit(.availabilityChanged(.poweredOn))
        XCTAssertEqual(central.connectCalls.count, connectsBefore + 1)
        XCTAssertEqual(central.pendingConnects, [strapA.identifier])
    }

    /// AC-26: a device remembered for both kinds serves both.
    func testACombinedDeviceServesBothKinds() async {
        store.remember(combined)
        store.remember(cadenceSensor)
        hub.acquire(.ride)
        await central.emit(.connected(combined.identifier))
        XCTAssertEqual(hub.assigned[.heartRate], combined.identifier)
        XCTAssertEqual(hub.assigned[.cadence], combined.identifier)
        XCTAssertEqual(central.cancelCalls, [cadenceSensor.identifier])
    }

    /// A sensor of one kind connecting keeps requests for the other kind.
    func testFillingOneKindKeepsLookingForTheOther() async {
        store.remember(strapA)
        store.remember(cadenceSensor)
        hub.acquire(.ride)
        await central.emit(.connected(strapA.identifier))
        XCTAssertEqual(central.pendingConnects, [cadenceSensor.identifier])
    }

    // MARK: - Cadence

    /// AC-36: cadence turns to 0 after the coasting timeout, through the periodic check.
    func testCoastingTurnsCadenceToZero() async {
        store.remember(cadenceSensor)
        hub.acquire(.ride)
        await central.emit(.connected(cadenceSensor.identifier))
        await central.emit(.cyclingSpeedAndCadenceMeasurement(cadenceSensor.identifier, crank(0, 0)))
        await clock.advance(by: 1)
        await central.emit(.cyclingSpeedAndCadenceMeasurement(cadenceSensor.identifier, crank(1, 683)))
        XCTAssertEqual(hub.rideReading.cadenceRPM, 90)

        await clock.advance(by: 3)
        await hub.checkCoasting()
        XCTAssertEqual(hub.rideReading.cadenceRPM, 0)
    }

    // MARK: - Screen holder

    /// AC-9: the screen connects every remembered sensor and keeps extras of a kind for live values.
    func testTheScreenKeepsEveryRememberedSensorConnected() async {
        store.remember(strapA)
        store.remember(strapB)
        hub.acquire(.screen)
        await central.emit(.connected(strapA.identifier))
        await central.emit(.connected(strapB.identifier))
        await central.emit(.heartRateMeasurement(strapB.identifier, heartRate(77)))
        XCTAssertEqual(central.cancelCalls, [])
        XCTAssertEqual(hub.readings[strapB.identifier]?.heartRateBPM, 77)
    }

    /// AC-10, RULE-11: leaving the screen with no ride ends every connection.
    func testLeavingTheScreenWithoutARideDisconnectsEverything() async {
        store.remember(strapA)
        hub.acquire(.screen)
        await central.emit(.connected(strapA.identifier))
        hub.release(.screen)
        XCTAssertEqual(central.cancelCalls, [strapA.identifier])
        XCTAssertTrue(hub.readings.isEmpty)
    }

    /// RULE-11: leaving the screen during a ride keeps the ride's sensor and drops only the extras.
    func testLeavingTheScreenDuringARideKeepsTheRidesSensor() async {
        store.remember(strapA)
        store.remember(strapB)
        hub.acquire(.ride)
        hub.acquire(.screen)
        await central.emit(.connected(strapA.identifier))
        await central.emit(.connected(strapB.identifier))
        hub.release(.screen)
        XCTAssertEqual(central.cancelCalls, [strapB.identifier])
        XCTAssertEqual(hub.assigned[.heartRate], strapA.identifier)
    }

    /// A sensor added on the screen connects straight away; one forgotten there disconnects.
    func testAddingAndForgettingOnTheScreen() async throws {
        hub.acquire(.screen)
        store.remember(strapA)
        hub.rememberedSensorsChanged()
        XCTAssertEqual(central.pendingConnects, [strapA.identifier])
        await central.emit(.connected(strapA.identifier))

        store.forget(try XCTUnwrap(store.sensors.first))
        hub.rememberedSensorsChanged()
        XCTAssertEqual(central.cancelCalls, [strapA.identifier])
        XCTAssertNil(hub.assigned[.heartRate])
    }

    // MARK: - Scanning

    /// AC-3, AC-4: only devices offering a supported kind are listed.
    func testScanListsOnlySupportedDevices() async {
        hub.startScan()
        XCTAssertTrue(central.isScanning)
        await central.emit(.discovered(strapA))
        await central.emit(.discovered(DiscoveredDevice(identifier: UUID(), name: "Speaker", kinds: [])))
        XCTAssertEqual(hub.discovered, [strapA])
        hub.stopScan()
        XCTAssertFalse(central.isScanning)
    }

    // MARK: - BluetoothSensorSource

    /// AC-16, AC-18, RULE-6: every sample carries both values, and a drop yields nil for that kind.
    func testTheSourceYieldsBothValuesAndDrops() async {
        store.remember(strapA)
        store.remember(cadenceSensor)
        let source = BluetoothSensorSource(hub: hub)
        var iterator = source.sensorUpdates().makeAsyncIterator()
        while central.pendingConnects.isEmpty { await Task.yield() }

        await central.emit(.connected(strapA.identifier))
        await central.emit(.connected(cadenceSensor.identifier))
        await central.emit(.cyclingSpeedAndCadenceMeasurement(cadenceSensor.identifier, crank(0, 0)))
        await clock.advance(by: 1)
        await central.emit(.cyclingSpeedAndCadenceMeasurement(cadenceSensor.identifier, crank(1, 683)))
        await central.emit(.heartRateMeasurement(strapA.identifier, heartRate(120)))

        let first = await iterator.next()
        XCTAssertEqual(first?.cadenceRPM, 90)
        XCTAssertNil(first?.heartRateBPM)
        let second = await iterator.next()
        XCTAssertEqual(second?.heartRateBPM, 120)
        XCTAssertEqual(second?.cadenceRPM, 90, "both fields every time")

        await central.emit(.disconnected(strapA.identifier))
        let third = await iterator.next()
        XCTAssertNil(third?.heartRateBPM)
        XCTAssertEqual(third?.cadenceRPM, 90)
    }
}

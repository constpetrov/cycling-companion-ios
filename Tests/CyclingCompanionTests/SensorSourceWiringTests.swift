import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// Milestone 12 task-3.2: AC-12, AC-15, AC-22, AC-25 (RULE-3, RULE-13).
@MainActor
final class SensorSourceWiringTests: XCTestCase {
    private var centralsCreated = 0

    private func dependencies(defaults: UserDefaults) -> AppDependencies {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppDependencies(
            baseURL: URL(string: "https://test.invalid")!, demoAccessToken: nil,
            routeStore: RouteStore(fileURL: directory.appendingPathComponent("routes.json")),
            rideStore: RideStore(fileURL: directory.appendingPathComponent("rides.json")),
            pendingUploadsFileURL: directory.appendingPathComponent("pending.json"),
            pointer: CurrentRoutePointer(defaults: defaults), notificationScheduling: PreviewNotificationScheduling(),
            keepScreenOnPreference: InMemoryKeepScreenOnPreference(), idleTimer: NoIdleTimer(),
            stopTypeSettings: StopTypeSettings(defaults: defaults), tokenStore: InMemoryTokenStore(token: "t"),
            transport: OfflineTransport(), sensorDefaults: defaults,
            makeBluetoothCentral: { [unowned self] in
                centralsCreated += 1
                return FakeBluetoothCentral()
            })
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SensorSourceWiringTests-\(UUID().uuidString)")!
    }

    /// AC-12: with nothing remembered, starting and resuming use no Bluetooth at all.
    func testNoRememberedSensorsMeansNoSensorSourceAndNoCentral() {
        let dependencies = dependencies(defaults: freshDefaults())
        XCTAssertTrue(dependencies.rideStarter.makeSensorSource() is NoSensorSource)
        XCTAssertTrue(dependencies.makeRideResumer().makeSensorSource() is NoSensorSource)
        XCTAssertEqual(centralsCreated, 0)
    }

    /// AC-22, RULE-13: with a remembered sensor, both a new ride and a resumed one use the hub.
    func testARememberedSensorMeansBluetoothForStartAndResume() {
        let dependencies = dependencies(defaults: freshDefaults())
        dependencies.sensorStore.remember(DiscoveredDevice(identifier: UUID(), name: "Strap", kinds: [.heartRate]))
        XCTAssertTrue(dependencies.rideStarter.makeSensorSource() is BluetoothSensorSource)
        XCTAssertTrue(dependencies.makeRideResumer().makeSensorSource() is BluetoothSensorSource)
        XCTAssertEqual(centralsCreated, 0, "making the source doesn't touch Bluetooth until the ride reads it")
    }

    /// AC-15: with Bluetooth off, the ride's stream simply stays empty; nothing throws or blocks.
    func testBluetoothOffYieldsNoReadings() async {
        let defaults = freshDefaults()
        let store = RememberedSensorStore(defaults: defaults)
        store.remember(DiscoveredDevice(identifier: UUID(), name: "Strap", kinds: [.heartRate]))
        let central = FakeBluetoothCentral(availability: .poweredOff)
        let hub = SensorHub(store: store, clock: ManualClock()) { central }
        let task = Task {
            for await _ in BluetoothSensorSource(hub: hub).sensorUpdates() {
                XCTFail("no reading expected")
            }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(central.connectCalls, [], "nothing is asked of Bluetooth while it is off")
        task.cancel()
        hub.release(.ride)
    }
}

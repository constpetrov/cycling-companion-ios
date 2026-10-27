#if DEBUG
import Foundation
import RoutePersistence

/// The `-uiTestFixtures` launch mode (RULE-30/RULE-31 in milestone 7's rules.md), compiled only in
/// Debug: a fresh, isolated data directory, a seeded current route that matches the bundled Demo
/// Mode replay, and a stub transport so UI tests never reach the shared backend.
enum UITestFixtures {
    static let launchArgument = "-uiTestFixtures"
    static let routeId = "ui-test-route"
    /// With this too, permissions read as While Using location and no notifications, so Start Ride
    /// shows the readiness sheet.
    static let missingPermissionsArgument = "-uiTestMissingPermissions"
    /// With this too, the app behaves as if a stop notification was tapped after launch, with no
    /// ride to show it on (AC-76).
    static let staleStopLinkArgument = "-uiTestStaleStopLink"
    /// With this too, the seeded route is stored as partly outside the stop data's region, so Home
    /// and the corridor map show the coverage message (milestone 8, RULE-21).
    static let partlyOutsideArgument = "-uiTestPartlyOutside"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Same graph as production, but on throwaway files, an isolated defaults suite, notifications
    /// that never post, and `StubBackendTransport`.
    @MainActor
    static func makeDependencies() -> AppDependencies {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ui-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ui-test-\(UUID().uuidString)") ?? .standard
        return AppDependencies(
            baseURL: URL(string: "https://ui-test.invalid")!, demoAccessToken: nil,
            routeStore: RouteStore(fileURL: directory.appendingPathComponent("routes.json")),
            rideStore: RideStore(fileURL: directory.appendingPathComponent("rides.json")),
            pendingUploadsFileURL: directory.appendingPathComponent("pending_ride_uploads.json"),
            pointer: CurrentRoutePointer(defaults: defaults), notificationScheduling: PreviewNotificationScheduling(),
            keepScreenOnPreference: InMemoryKeepScreenOnPreference(), idleTimer: NoIdleTimer(),
            stopTypeSettings: StopTypeSettings(defaults: defaults),
            permissions: ProcessInfo.processInfo.arguments.contains(missingPermissionsArgument)
                ? PartialPermissions() : GrantedPermissions(),
            // Milestone 10: UI tests start signed in, with a session the stub backend accepts.
            tokenStore: InMemoryTokenStore(token: "ui-test-refresh-token"), initialAccessToken: "ui-test-access-token",
            accountMemory: AccountMemory(defaults: defaults), transport: StubBackendTransport())
    }

    /// Seeds a ready route running north along the Demo Mode replay (52.0°N → 52.03°N at 13.0°E),
    /// with a café and a bakery beside it, and makes it the current route.
    @MainActor
    static func seed(_ dependencies: AppDependencies) async {
        let metersPerDegreeLatitude = GeoMath.earthRadiusMeters * .pi / 180
        let points = stride(from: 0, through: 30, by: 1).map { step -> PersistedPointInput in
            let latitude = 52.0 + Double(step) * 0.001
            return PersistedPointInput(
                latitude: latitude, longitude: 13.0, elevationMeters: 40 + Double(step % 7),
                cumulativeDistanceMeters: (latitude - 52.0) * metersPerDegreeLatitude)
        }
        let pois = [
            // Late along the replay: the advisor's 10-minute quiet period (ride time) ends with the
            // rider about 1.3 km in, so stops must still be ahead then for a suggestion to pass.
            PersistedPoiInput(
                osmId: 1_001, type: "CAFE", name: "Café am Kanal", latitude: 52.0207, longitude: 13.0015,
                kmMarkMeters: 0.0207 * metersPerDegreeLatitude, detourMeters: 110, openingHours: nil),
            PersistedPoiInput(
                osmId: 1_002, type: "BAKERY", name: "Bäckerei Nord", latitude: 52.0235, longitude: 12.9988,
                kmMarkMeters: 0.0235 * metersPerDegreeLatitude, detourMeters: 85, openingHours: nil),
        ]
        try? await dependencies.routeStore.persist(
            routeId: routeId, hash: "ui-test", totalDistanceMeters: points.last?.cumulativeDistanceMeters ?? 0,
            totalClimbingMeters: 42, points: points, pois: pois, status: "ready", displayName: "Canal Loop",
            coverageRegion: ProcessInfo.processInfo.arguments.contains(partlyOutsideArgument) ? "Netherlands" : nil,
            outsideMeters: ProcessInfo.processInfo.arguments.contains(partlyOutsideArgument) ? 1_400 : nil)
        dependencies.pointer.routeId = routeId
        await dependencies.homeViewModel.refresh()
    }

    /// After the launch-time resume: replays a tap on a notification for the seeded café.
    @MainActor
    static func simulateNotificationTapIfRequested(_ appDelegate: AppDelegate) {
        guard ProcessInfo.processInfo.arguments.contains(staleStopLinkArgument) else { return }
        appDelegate.handleNotificationTap(userInfo: ["stopId": "1001"])
    }
}

/// While Using location, notifications denied: enough to start, with the warning and the
/// "Start without suggestions" button.
@MainActor
struct PartialPermissions: PermissionStatusProviding {
    func current() async -> PermissionSnapshot {
        PermissionSnapshot(location: .whenInUse, preciseLocation: true, notifications: .denied)
    }

    func requestLocationWhenInUse() async {}
    func requestLocationAlways() async {}
    func requestNotifications() async {}
    func openSettings() {}
}

/// Answers every backend call the app makes, offline: a session refresh, an advisor decision
/// suggesting the seeded café, and a successful ride ingest.
struct StubBackendTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("auth/refresh") {
            body = #"{"accessToken":"ui-test-access-token","refreshToken":"ui-test-refresh-token","riderId":"00000000-0000-0000-0000-000000000001","accessTokenExpiresIn":3600}"#
        } else if path.contains("advisor") {
            // Always suggests the seeded café, so the screenshot tour can show the card and sheet.
            body = #"{"suggest":true,"stopId":"1001","urgency":"low","reason":"time for a break","message":"Café am Kanal is just ahead — fancy a coffee?"}"#
        } else {
            body = #"{"rideId":"00000000-0000-0000-0000-000000000002"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
/// Debug-only end-to-end hook (milestone 8 task-5.3): `-e2eImportGPX <path>` imports that GPX file
/// at launch through the same path as the file picker, against whatever backend the build points at.
enum EndToEndHooks {
    static let importArgument = "-e2eImportGPX"

    @MainActor
    static func importIfRequested(_ dependencies: AppDependencies) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: importArgument), index + 1 < arguments.count else { return }
        await dependencies.homeViewModel.importGPX(from: URL(fileURLWithPath: arguments[index + 1]))
    }
}
#endif

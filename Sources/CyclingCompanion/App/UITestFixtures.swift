#if DEBUG
import Foundation
import RoutePersistence

/// The `-uiTestFixtures` launch mode (RULE-30/RULE-31 in milestone 7's rules.md), compiled only in
/// Debug: a fresh, isolated data directory, a seeded current route that matches the bundled Demo
/// Mode replay, and a stub transport so UI tests never reach the shared backend.
enum UITestFixtures {
    static let launchArgument = "-uiTestFixtures"
    static let routeId = "ui-test-route"

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
            transport: StubBackendTransport())
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
            PersistedPoiInput(
                osmId: 1_001, type: "CAFE", name: "Café am Kanal", latitude: 52.0125, longitude: 13.0015,
                kmMarkMeters: 0.0125 * metersPerDegreeLatitude, detourMeters: 110, openingHours: nil),
            PersistedPoiInput(
                osmId: 1_002, type: "BAKERY", name: "Bäckerei Nord", latitude: 52.0215, longitude: 12.9988,
                kmMarkMeters: 0.0215 * metersPerDegreeLatitude, detourMeters: 85, openingHours: nil),
        ]
        try? await dependencies.routeStore.persist(
            routeId: routeId, hash: "ui-test", totalDistanceMeters: points.last?.cumulativeDistanceMeters ?? 0,
            totalClimbingMeters: 42, points: points, pois: pois, status: "ready")
        dependencies.pointer.routeId = routeId
        await dependencies.homeViewModel.refresh()
    }
}

/// Answers every backend call the app makes, offline: sign-in, a no-suggestion advisor decision,
/// and a successful ride ingest.
struct StubBackendTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let body: String
        if path.hasSuffix("sign-in") {
            body = #"{"token":"ui-test-token","riderId":"00000000-0000-0000-0000-000000000001"}"#
        } else if path.contains("advisor") {
            body = #"{"suggest":false}"#
        } else {
            body = #"{"rideId":"00000000-0000-0000-0000-000000000002"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
#endif

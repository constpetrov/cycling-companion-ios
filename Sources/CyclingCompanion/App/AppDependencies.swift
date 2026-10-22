import Foundation
import RoutePersistence
import UserNotifications

/// Every long-lived object the app uses, built once in `CyclingCompanionApp.init` and handed to the
/// view tree with `.environment(_:)` (RULE-5 in milestone 7's rules.md). Views read it with
/// `@Environment(AppDependencies.self)` and never construct stores, clients, coordinators or
/// `CurrentRoutePointer` themselves. `preview` builds the same graph on temporary files and a
/// transport that never reaches the network (RULE-6).
@MainActor
@Observable
final class AppDependencies {
    let appRouter: AppRouter
    let rideCoordinator: RideCoordinator
    let routeStore: RouteStore
    let rideStore: RideStore
    let pointer: CurrentRoutePointer
    let decisionLog: DecisionLog
    let notifier: Notifier
    let authClient: AuthStubClient
    let lazySignIn: LazySignIn
    let advisorClient: AdvisorClient
    let corridorImportCoordinator: CorridorImportCoordinator
    let rideStarter: RideStarter
    let rideFinisher: RideFinisher
    let rideIngestClient: RideIngestClient
    let pendingUploadQueue: PendingRideUploadQueue
    let homeViewModel: HomeViewModel

    init(
        baseURL: URL, demoAccessToken: String?, routeStore: RouteStore, rideStore: RideStore,
        pendingUploadsFileURL: URL, pointer: CurrentRoutePointer, notificationScheduling: NotificationScheduling,
        transport: HTTPTransport = URLSession.shared
    ) {
        let decisionLog = DecisionLog()
        let notifier = Notifier(scheduling: notificationScheduling, log: decisionLog)
        let authClient = AuthStubClient(baseURL: baseURL, transport: transport, demoAccessToken: demoAccessToken)
        let lazySignIn = LazySignIn(authClient: authClient)
        // The HTTP deadline uses wall-clock time, even during an accelerated demo replay.
        let advisorClient = AdvisorClient(
            baseURL: baseURL, authClient: authClient, lazySignIn: lazySignIn, transport: transport)
        let appRouter = AppRouter()
        let rideCoordinator = RideCoordinator()
        let rideIngestClient = RideIngestClient(
            baseURL: baseURL, authClient: authClient, lazySignIn: lazySignIn, transport: transport)
        let pendingUploadQueue = PendingRideUploadQueue(fileURL: pendingUploadsFileURL)

        self.appRouter = appRouter
        self.rideCoordinator = rideCoordinator
        self.routeStore = routeStore
        self.rideStore = rideStore
        self.pointer = pointer
        self.decisionLog = decisionLog
        self.notifier = notifier
        self.authClient = authClient
        self.lazySignIn = lazySignIn
        self.advisorClient = advisorClient
        self.corridorImportCoordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(baseURL: baseURL, authClient: authClient, transport: transport),
            routeStore: routeStore, pointer: pointer, appRouter: appRouter, lazySignIn: lazySignIn)
        self.rideStarter = RideStarter(
            routeStore: routeStore, rideStore: rideStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, advisorClient: advisorClient)
        self.rideIngestClient = rideIngestClient
        self.pendingUploadQueue = pendingUploadQueue
        self.rideFinisher = RideFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator,
            decisionLog: decisionLog, rideStore: rideStore, rideIngestClient: rideIngestClient,
            pendingUploadQueue: pendingUploadQueue)
        self.homeViewModel = HomeViewModel(routeStore: routeStore, pointer: pointer)
    }

    /// The production graph for `configuration`, on the app's real files and `URLSession`.
    static func live(configuration: BackendConfiguration) -> AppDependencies {
        let temporary = FileManager.default.temporaryDirectory
        let pendingUploadsFileURL =
            ((try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? temporary).appendingPathComponent("pending_ride_uploads.json")
        return AppDependencies(
            baseURL: configuration.baseURL, demoAccessToken: configuration.demoAccessToken,
            routeStore: RouteStore(
                fileURL: (try? RouteStore.defaultFileURL()) ?? temporary.appendingPathComponent("routes.json")),
            rideStore: RideStore(
                fileURL: (try? RideStore.defaultFileURL()) ?? temporary.appendingPathComponent("rides.json")),
            pendingUploadsFileURL: pendingUploadsFileURL, pointer: CurrentRoutePointer(),
            notificationScheduling: UNUserNotificationCenter.current())
    }

    func makeRideResumer() -> RideResumer {
        RideResumer(
            rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, advisorClient: advisorClient)
    }

    func makePendingRideUploadRetrier() -> PendingRideUploadRetrier {
        PendingRideUploadRetrier(pendingUploadQueue: pendingUploadQueue, rideIngestClient: rideIngestClient)
    }

    /// Type-erased so always-compiled views never need to name `DemoRideStarter` (RULE-15): only
    /// this construction site, itself `#if DEBUG`, does. Returns `nil` in Release.
    func startDemoRide(speed: Double) async -> RideSession? {
        #if DEBUG
        let fixture = DemoFixture.loadBundled()
        let starter = DemoRideStarter(
            routeStore: routeStore, rideStore: rideStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, locationFixes: fixture.locationFixes, sensorSamples: fixture.sensorSamples,
            advisorClient: advisorClient)
        return await starter.startDemoRide(speed: speed)
        #else
        return nil
        #endif
    }
}

#if DEBUG
/// A transport for previews that fails every request as offline, so a preview can never reach a
/// backend (RULE-6).
struct OfflineTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

extension AppDependencies {
    /// Fake-backed graph for `#Preview`s: stores in fresh temporary files, an isolated
    /// `UserDefaults` suite for the route pointer, notifications that are never scheduled, and
    /// `OfflineTransport`.
    static var preview: AppDependencies {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "preview-\(UUID().uuidString)") ?? .standard
        return AppDependencies(
            baseURL: URL(string: "https://preview.invalid")!, demoAccessToken: nil,
            routeStore: RouteStore(fileURL: directory.appendingPathComponent("routes.json")),
            rideStore: RideStore(fileURL: directory.appendingPathComponent("rides.json")),
            pendingUploadsFileURL: directory.appendingPathComponent("pending_ride_uploads.json"),
            pointer: CurrentRoutePointer(defaults: defaults), notificationScheduling: PreviewNotificationScheduling(),
            transport: OfflineTransport())
    }
}

/// Notification scheduling that grants nothing and posts nothing, for previews.
struct PreviewNotificationScheduling: NotificationScheduling {
    func requestAuthorization() async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func add(_ request: UNNotificationRequest) async throws {}
}
#endif

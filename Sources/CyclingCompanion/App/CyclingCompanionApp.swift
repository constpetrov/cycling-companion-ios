import RoutePersistence
import SwiftUI
import UserNotifications

@main
struct CyclingCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let configurationError: String?
    private let appRouter: AppRouter
    private let rideCoordinator: RideCoordinator
    private let routeStore: RouteStore
    private let rideStore: RideStore
    private let pointer: CurrentRoutePointer
    private let decisionLog: DecisionLog
    private let notifier: Notifier
    private let authClient: AuthStubClient
    private let lazySignIn: LazySignIn
    private let advisorClient: AdvisorClient
    private let coordinator: CorridorImportCoordinator
    private let rideStarter: RideStarter
    private let rideFinisher: RideFinisher
    private let rideIngestClient: RideIngestClient
    private let pendingUploadQueue: PendingRideUploadQueue

    init() {
        let configuration: BackendConfiguration
        do {
            configuration = try BackendConfiguration.load()
            self.configurationError = nil
        } catch {
            // Construct inert dependencies, but show the configuration error instead of
            // starting network requests or resuming a ride against a wrong server.
            configuration = .local
            self.configurationError = error.localizedDescription
        }
        let routeStore = RouteStore(fileURL: (try? RouteStore.defaultFileURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("routes.json"))
        let rideStore = RideStore(fileURL: (try? RideStore.defaultFileURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("rides.json"))
        let pendingUploadsFileURL =
            ((try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("pending_ride_uploads.json")
        let decisionLog = DecisionLog()
        let notifier = Notifier(scheduling: UNUserNotificationCenter.current(), log: decisionLog)
        let authClient = AuthStubClient(baseURL: configuration.baseURL, demoAccessToken: configuration.demoAccessToken)
        let lazySignIn = LazySignIn(authClient: authClient)
        // The HTTP deadline uses wall-clock time, even during an accelerated demo replay.
        let advisorClient = AdvisorClient(baseURL: configuration.baseURL, authClient: authClient, lazySignIn: lazySignIn)
        let appRouter = AppRouter()
        let rideCoordinator = RideCoordinator()
        let pointer = CurrentRoutePointer()

        self.routeStore = routeStore
        self.rideStore = rideStore
        self.decisionLog = decisionLog
        self.notifier = notifier
        self.authClient = authClient
        self.lazySignIn = lazySignIn
        self.advisorClient = advisorClient
        self.appRouter = appRouter
        self.rideCoordinator = rideCoordinator
        self.pointer = pointer
        self.coordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(baseURL: configuration.baseURL, authClient: authClient),
            routeStore: routeStore, pointer: pointer, appRouter: appRouter, lazySignIn: lazySignIn)
        self.rideStarter = RideStarter(
            routeStore: routeStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, advisorClient: advisorClient)
        self.rideIngestClient = RideIngestClient(baseURL: configuration.baseURL, authClient: authClient, lazySignIn: lazySignIn)
        self.pendingUploadQueue = PendingRideUploadQueue(fileURL: pendingUploadsFileURL)
        self.rideFinisher = RideFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            rideStore: rideStore, rideIngestClient: rideIngestClient, pendingUploadQueue: pendingUploadQueue)

        appDelegate.appRouter = appRouter
    }

    var body: some Scene {
        WindowGroup {
            if let configurationError {
                ContentUnavailableView(
                    "Backend configuration required", systemImage: "network",
                    description: Text(configurationError))
            } else {
                ContentView(
                    appRouter: appRouter, rideCoordinator: rideCoordinator, routeStore: routeStore,
                    coordinator: coordinator, rideStarter: rideStarter,
                    rideFinisher: rideFinisher, onStartDemoRide: startDemoRide
                )
                .task {
                    await RideResumer(
                        rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
                        notifier: notifier, advisorClient: advisorClient
                    ).resumeIfNeeded()
                    await PendingRideUploadRetrier(pendingUploadQueue: pendingUploadQueue, rideIngestClient: rideIngestClient)
                        .retryPendingUploads()
                }
            }
        }
    }

    /// Type-erased so `ContentView`/`HomeView` (always compiled) never need to name
    /// `DemoRideStarter` themselves (RULE-15) — only this construction site, itself `#if DEBUG`,
    /// does.
    private func startDemoRide(speed: Double) async -> RideSession? {
        #if DEBUG
        let fixture = DemoFixture.loadBundled()
        let starter = DemoRideStarter(
            routeStore: routeStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, locationFixes: fixture.locationFixes, sensorSamples: fixture.sensorSamples,
            advisorClient: advisorClient)
        return await starter.startDemoRide(speed: speed)
        #else
        return nil
        #endif
    }
}

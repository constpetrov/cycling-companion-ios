import RoutePersistence
import SwiftUI
import UserNotifications

@main
struct CyclingCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Dev-only: the backend's default local port (Spring Boot's own default, confirmed
    /// against `application.yml`). The Simulator reaches the host Mac's `localhost` directly;
    /// iOS exempts loopback addresses from App Transport Security, so no Info.plist exception
    /// is needed.
    private static let backendBaseURL = URL(string: "http://localhost:8080")!

    private let appRouter: AppRouter
    private let routeStore: RouteStore
    private let rideStore: RideStore
    private let pointer: CurrentRoutePointer
    private let decisionLog: DecisionLog
    private let notifier: Notifier
    private let authClient: AuthStubClient
    private let lazySignIn: LazySignIn
    private let coordinator: CorridorImportCoordinator
    private let rideStarter: RideStarter
    private let rideFinisher: RideFinisher
    private let rideIngestClient: RideIngestClient
    private let pendingUploadQueue: PendingRideUploadQueue

    init() {
        let routeStore = RouteStore(fileURL: (try? RouteStore.defaultFileURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("routes.json"))
        let rideStore = RideStore(fileURL: (try? RideStore.defaultFileURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("rides.json"))
        let pendingUploadsFileURL =
            ((try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("pending_ride_uploads.json")
        let decisionLog = DecisionLog()
        let notifier = Notifier(scheduling: UNUserNotificationCenter.current(), log: decisionLog)
        let authClient = AuthStubClient(baseURL: Self.backendBaseURL)
        let lazySignIn = LazySignIn(authClient: authClient)
        let appRouter = AppRouter()
        let pointer = CurrentRoutePointer()

        self.routeStore = routeStore
        self.rideStore = rideStore
        self.decisionLog = decisionLog
        self.notifier = notifier
        self.authClient = authClient
        self.lazySignIn = lazySignIn
        self.appRouter = appRouter
        self.pointer = pointer
        self.coordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(baseURL: Self.backendBaseURL, authClient: authClient),
            routeStore: routeStore, pointer: pointer, appRouter: appRouter, lazySignIn: lazySignIn)
        self.rideStarter = RideStarter(
            routeStore: routeStore, pointer: pointer, appRouter: appRouter, decisionLog: decisionLog,
            notifier: notifier)
        self.rideIngestClient = RideIngestClient(baseURL: Self.backendBaseURL, authClient: authClient, lazySignIn: lazySignIn)
        self.pendingUploadQueue = PendingRideUploadQueue(fileURL: pendingUploadsFileURL)
        self.rideFinisher = RideFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), appRouter: appRouter, decisionLog: decisionLog,
            rideStore: rideStore, rideIngestClient: rideIngestClient, pendingUploadQueue: pendingUploadQueue)

        appDelegate.appRouter = appRouter
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                appRouter: appRouter, routeStore: routeStore, coordinator: coordinator, rideStarter: rideStarter,
                rideFinisher: rideFinisher, onStartDemoRide: startDemoRide
            )
            .task {
                await RideResumer(
                    rideStore: rideStore, routeStore: routeStore, appRouter: appRouter, decisionLog: decisionLog,
                    notifier: notifier
                ).resumeIfNeeded()
                await PendingRideUploadRetrier(pendingUploadQueue: pendingUploadQueue, rideIngestClient: rideIngestClient)
                    .retryPendingUploads()
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
            routeStore: routeStore, pointer: pointer, appRouter: appRouter, decisionLog: decisionLog,
            notifier: notifier, locationFixes: fixture.locationFixes, sensorSamples: fixture.sensorSamples)
        return await starter.startDemoRide(speed: speed)
        #else
        return nil
        #endif
    }
}

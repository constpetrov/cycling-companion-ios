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
    let authAPI: AuthAPIClient
    let authSession: AuthSession
    let sessionState: SessionState
    let accountMemory: AccountMemory
    let accountActions: AccountActions
    let advisorClient: AdvisorClient
    let corridorImportCoordinator: CorridorImportCoordinator
    let rideStarter: RideStarter
    let rideFinisher: RideFinisher
    let rideIngestClient: RideIngestClient
    let pendingUploadQueue: PendingRideUploadQueue
    let rideUploader: RideUploader
    let homeViewModel: HomeViewModel
    let keepScreenOnPreference: KeepScreenOnPreference
    let stopTypeSettings: StopTypeSettings
    let idleTimer: IdleTimerControlling
    let directions: DirectionsOpening
    let rideStartFlow: RideStartFlow

    init(
        baseURL: URL, demoAccessToken: String?, routeStore: RouteStore, rideStore: RideStore,
        pendingUploadsFileURL: URL, pointer: CurrentRoutePointer, notificationScheduling: NotificationScheduling,
        keepScreenOnPreference: KeepScreenOnPreference, idleTimer: IdleTimerControlling,
        stopTypeSettings: StopTypeSettings,
        directions: DirectionsOpening = NoDirections(), permissions: PermissionStatusProviding = GrantedPermissions(),
        tokenStore: TokenStore, initialAccessToken: String? = nil, accountMemory: AccountMemory = AccountMemory(),
        transport: HTTPTransport = URLSession.shared
    ) {
        let decisionLog = DecisionLog()
        let notifier = Notifier(scheduling: notificationScheduling, log: decisionLog)
        // Milestone 10 (RULE-32): one session signs every authenticated request.
        let authAPI = AuthAPIClient(baseURL: baseURL, transport: transport, demoAccessToken: demoAccessToken)
        let authSession = AuthSession(
            api: authAPI, tokenStore: tokenStore, transport: transport, accessToken: initialAccessToken)
        // RULE-37: signed in when a refresh token is stored (a locked Keychain still has one).
        let hasStoredSession: Bool
        do {
            hasStoredSession = try tokenStore.load() != nil
        } catch {
            hasStoredSession = true
        }
        let sessionState = SessionState(
            status: hasStoredSession ? .signedIn(riderId: accountMemory.riderId ?? "") : .signedOut)
        sessionState.observe(authSession.events)
        // The HTTP deadline uses wall-clock time, even during an accelerated demo replay.
        let advisorClient = AdvisorClient(baseURL: baseURL, session: authSession)
        let appRouter = AppRouter()
        let rideCoordinator = RideCoordinator()
        let rideIngestClient = RideIngestClient(baseURL: baseURL, session: authSession)
        let pendingUploadQueue = PendingRideUploadQueue(fileURL: pendingUploadsFileURL)

        self.appRouter = appRouter
        self.rideCoordinator = rideCoordinator
        self.routeStore = routeStore
        self.rideStore = rideStore
        self.pointer = pointer
        self.decisionLog = decisionLog
        self.notifier = notifier
        self.authAPI = authAPI
        self.authSession = authSession
        self.sessionState = sessionState
        self.accountMemory = accountMemory
        self.accountActions = AccountActions(
            api: authAPI, session: authSession, sessionState: sessionState, accountMemory: accountMemory)
        self.advisorClient = advisorClient
        let corridorImportCoordinator = CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(baseURL: baseURL, session: authSession),
            routeStore: routeStore, pointer: pointer, appRouter: appRouter)
        self.corridorImportCoordinator = corridorImportCoordinator
        let rideStarter = RideStarter(
            routeStore: routeStore, rideStore: rideStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, advisorClient: advisorClient, stopTypeFilter: stopTypeSettings.filter)
        self.rideStarter = rideStarter
        self.rideIngestClient = rideIngestClient
        self.pendingUploadQueue = pendingUploadQueue
        let rideUploader = RideUploader(ingestClient: rideIngestClient, queue: pendingUploadQueue)
        self.rideUploader = rideUploader
        self.rideFinisher = RideFinisher(
            rideRecorder: RideRecorder(rideStore: rideStore), rideCoordinator: rideCoordinator,
            decisionLog: decisionLog, rideStore: rideStore, uploader: rideUploader)
        self.homeViewModel = HomeViewModel(
            routeStore: routeStore, pointer: pointer, importer: corridorImportCoordinator, rideStore: rideStore)
        self.keepScreenOnPreference = keepScreenOnPreference
        self.stopTypeSettings = stopTypeSettings
        self.idleTimer = idleTimer
        self.directions = directions
        self.rideStartFlow = RideStartFlow(
            readiness: ReadinessViewModel(permissions: permissions), start: { await rideStarter.startRide() })
    }

    /// The production graph for `configuration`, on the app's real files and `URLSession`.
    static func live(configuration: BackendConfiguration) -> AppDependencies {
        let tokenStore = KeychainTokenStore()
        // RULE-36: before anything can sign in with a token left by a previous install.
        FirstLaunchCheck.run(defaults: .standard, tokenStore: tokenStore)
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
            notificationScheduling: UNUserNotificationCenter.current(),
            keepScreenOnPreference: UserDefaultsKeepScreenOnPreference(), idleTimer: ApplicationIdleTimer(),
            stopTypeSettings: StopTypeSettings(),
            directions: AppleMapsDirections(), permissions: SystemPermissions(), tokenStore: tokenStore)
    }

    func makeRideResumer() -> RideResumer {
        let homeViewModel = homeViewModel
        return RideResumer(
            rideStore: rideStore, routeStore: routeStore, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, advisorClient: advisorClient, stopTypeFilter: stopTypeSettings.filter,
            onOrphanedRide: { homeViewModel.reportOrphanedRide(id: $0) })
    }

    func makePendingRideUploadRetrier() -> PendingRideUploadRetrier {
        PendingRideUploadRetrier(
            pendingUploadQueue: pendingUploadQueue, rideIngestClient: rideIngestClient, rideStore: rideStore)
    }

    /// Type-erased so always-compiled views never need to name `DemoRideStarter` (RULE-15): only
    /// this construction site, itself `#if DEBUG`, does. Returns `nil` in Release.
    func startDemoRide(speed: Double) async -> RideSession? {
        #if DEBUG
        let fixture = DemoFixture.loadBundled()
        let starter = DemoRideStarter(
            routeStore: routeStore, rideStore: rideStore, pointer: pointer, rideCoordinator: rideCoordinator, decisionLog: decisionLog,
            notifier: notifier, locationFixes: fixture.locationFixes, sensorSamples: fixture.sensorSamples,
            advisorClient: advisorClient, stopTypeFilter: stopTypeSettings.filter)
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
            keepScreenOnPreference: InMemoryKeepScreenOnPreference(), idleTimer: NoIdleTimer(),
            stopTypeSettings: StopTypeSettings(defaults: defaults),
            tokenStore: InMemoryTokenStore(token: "preview-refresh-token"), initialAccessToken: "preview-access-token",
            accountMemory: AccountMemory(defaults: defaults), transport: OfflineTransport())
    }
}

/// Notification scheduling that grants nothing and posts nothing, for previews.
struct PreviewNotificationScheduling: NotificationScheduling {
    func requestAuthorization() async throws -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func add(_ request: UNNotificationRequest) async throws {}
}
#endif

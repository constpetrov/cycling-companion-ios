import RoutePersistence
import SwiftUI
import UserNotifications

/// The app's root view (RULE-9 in spec/rules.md): the live ride whenever `RideCoordinator` has
/// an active ride, otherwise Home or the corridor map from `appRouter.currentScreen`. It never
/// decides anything itself. `onStartDemoRide` is a type-erased closure (not a `DemoRideStarter`
/// reference) so this always-compiled file never needs to name a `#if DEBUG`-only type (RULE-15).
struct ContentView: View {
    let appRouter: AppRouter
    let rideCoordinator: RideCoordinator
    let routeStore: RouteStore
    let coordinator: CorridorImportCoordinator
    let rideStarter: RideStarter
    let rideFinisher: RideFinisher
    let onStartDemoRide: (Double) async -> RideSession?

    var body: some View {
        if let liveRide = rideCoordinator.activeRide {
            LiveRideScreen(
                rideTracker: liveRide.tracker,
                onFinishRide: { Task { await rideFinisher.finishRide(liveRide) } })
        } else {
            NavigationStack {
                screen
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch appRouter.currentScreen {
        case .home:
            HomeView(
                routeStore: routeStore, coordinator: coordinator,
                onStartRide: { Task { await rideStarter.startRide() } }, onStartDemoRide: onStartDemoRide)
        case .corridorMap:
            CorridorMapScreen(coordinator: coordinator, onStartRide: { Task { await rideStarter.startRide() } })
        }
    }
}

#Preview {
    ContentView(
        appRouter: AppRouter(), rideCoordinator: RideCoordinator(),
        routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-routes.json")),
        coordinator: CorridorImportCoordinator(
            corridorPollingService: CorridorPollingService(
                baseURL: URL(string: "http://localhost:8080")!,
                authClient: AuthStubClient(baseURL: URL(string: "http://localhost:8080")!)),
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-routes.json")),
            pointer: CurrentRoutePointer(), appRouter: AppRouter(),
            lazySignIn: LazySignIn(authClient: AuthStubClient(baseURL: URL(string: "http://localhost:8080")!))),
        rideStarter: RideStarter(
            routeStore: RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-routes.json")),
            pointer: CurrentRoutePointer(), rideCoordinator: RideCoordinator(), decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: UNUserNotificationCenter.current(), log: DecisionLog())),
        rideFinisher: RideFinisher(
            rideRecorder: RideRecorder(
                rideStore: RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-rides.json"))),
            rideCoordinator: RideCoordinator(), decisionLog: DecisionLog(),
            rideStore: RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-rides.json")),
            rideIngestClient: RideIngestClient(
                baseURL: URL(string: "http://localhost:8080")!,
                authClient: AuthStubClient(baseURL: URL(string: "http://localhost:8080")!),
                lazySignIn: LazySignIn(authClient: AuthStubClient(baseURL: URL(string: "http://localhost:8080")!))),
            pendingUploadQueue: PendingRideUploadQueue(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-pending-uploads.json"))),
        onStartDemoRide: { _ in nil })
}

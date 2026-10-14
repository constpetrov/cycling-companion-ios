import RoutePersistence
import SwiftUI
import UserNotifications

/// The app's root view (RULE-9 in spec/rules.md) — switches between Home, the corridor map,
/// and the live ride screen purely off `appRouter.currentScreen`; it never decides anything
/// itself. `onStartDemoRide` is a type-erased closure (not a `DemoRideStarter` reference) so
/// this always-compiled file never needs to name a `#if DEBUG`-only type (RULE-15).
struct ContentView: View {
    let appRouter: AppRouter
    let routeStore: RouteStore
    let coordinator: CorridorImportCoordinator
    let rideStarter: RideStarter
    let rideFinisher: RideFinisher
    let onStartDemoRide: (Double) async -> RideSession?

    var body: some View {
        NavigationStack {
            screen
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
        case .liveRide(let liveRide):
            LiveRideScreen(
                rideTracker: liveRide?.tracker,
                onFinishRide: {
                    guard let liveRide else { return }
                    Task { await rideFinisher.finishRide(liveRide) }
                })
        }
    }
}

#Preview {
    ContentView(
        appRouter: AppRouter(),
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
            pointer: CurrentRoutePointer(), appRouter: AppRouter(), decisionLog: DecisionLog(),
            notifier: Notifier(scheduling: UNUserNotificationCenter.current(), log: DecisionLog())),
        rideFinisher: RideFinisher(
            rideRecorder: RideRecorder(
                rideStore: RideStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-rides.json"))),
            appRouter: AppRouter()),
        onStartDemoRide: { _ in nil })
}

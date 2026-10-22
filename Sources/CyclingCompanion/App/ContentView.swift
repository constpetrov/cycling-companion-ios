import SwiftUI

/// The app's root view (RULE-7/RULE-9): the live ride whenever `RideCoordinator` has an active
/// ride, otherwise a `NavigationStack` rooted at Home whose pushed screens come from
/// `AppRouter.path`. It never decides anything itself; everything comes from `AppDependencies`.
struct ContentView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        if let liveRide = dependencies.rideCoordinator.activeRide {
            LiveRideScreen(
                rideTracker: liveRide.tracker,
                onFinishRide: { Task { await dependencies.rideFinisher.finishRide(liveRide) } })
        } else {
            @Bindable var router = dependencies.appRouter
            NavigationStack(path: $router.path) {
                HomeView()
                    .navigationDestination(for: HomeRoute.self, destination: destination)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: HomeRoute) -> some View {
        switch route {
        case .corridorMap:
            CorridorMapScreen(
                coordinator: dependencies.corridorImportCoordinator,
                onStartRide: { Task { await dependencies.rideStarter.startRide() } })
        #if DEBUG
        case .demo:
            DemoModeScreen(onStart: dependencies.startDemoRide(speed:))
        #endif
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environment(AppDependencies.preview)
}
#endif

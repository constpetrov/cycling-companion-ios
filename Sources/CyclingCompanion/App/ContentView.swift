import SwiftUI

/// The app's root view (RULE-9 in spec/rules.md): the live ride whenever `RideCoordinator` has an
/// active ride, otherwise Home or the corridor map from `AppRouter.currentScreen`. It never
/// decides anything itself; everything comes from `AppDependencies` in the environment.
struct ContentView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        if let liveRide = dependencies.rideCoordinator.activeRide {
            LiveRideScreen(
                rideTracker: liveRide.tracker,
                onFinishRide: { Task { await dependencies.rideFinisher.finishRide(liveRide) } })
        } else {
            NavigationStack {
                screen
            }
        }
    }

    @ViewBuilder
    private var screen: some View {
        switch dependencies.appRouter.currentScreen {
        case .home:
            HomeView()
        case .corridorMap:
            CorridorMapScreen(
                coordinator: dependencies.corridorImportCoordinator,
                onStartRide: { Task { await dependencies.rideStarter.startRide() } })
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environment(AppDependencies.preview)
}
#endif

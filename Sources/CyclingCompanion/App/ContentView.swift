import SwiftUI

/// The app's root view (RULE-7/RULE-9): a `NavigationStack` rooted at Home whose pushed screens
/// come from `AppRouter.path`, with the ride (live, then its summary) in a full-screen cover driven
/// by `RideCoordinator.presentation`. It never decides anything itself; everything comes from `AppDependencies`.
struct ContentView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        @Bindable var router = dependencies.appRouter
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: HomeRoute.self, destination: destination)
        }
        .fullScreenCover(item: ridePresentation) { presentation in
            Group {
                switch presentation {
                case .live(let liveRide):
                    LiveRideScreen(
                        viewModel: LiveRideViewModel(
                            tracker: liveRide.tracker, keepScreenOnPreference: dependencies.keepScreenOnPreference,
                            idleTimer: dependencies.idleTimer),
                        onFinishRide: { Task { await dependencies.rideFinisher.finishRide(liveRide) } })
                case .summary(let outcome):
                    RideSummaryView(outcome: outcome, onDone: dependencies.rideCoordinator.dismissSummary)
                }
            }
            .interactiveDismissDisabled()
        }
    }

    /// The cover follows `RideCoordinator.presentation` (RULE-7). It can only be closed by the
    /// summary's Done, so the only write that reaches the setter is that dismissal.
    private var ridePresentation: Binding<RidePresentation?> {
        Binding(
            get: { dependencies.rideCoordinator.presentation },
            set: { if $0 == nil { dependencies.rideCoordinator.dismissSummary() } })
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

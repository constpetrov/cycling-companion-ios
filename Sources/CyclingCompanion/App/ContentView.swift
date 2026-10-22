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
        .sheet(isPresented: readinessSheetPresented) {
            ReadinessSheet(flow: dependencies.rideStartFlow)
        }
        .fullScreenCover(item: ridePresentation) { presentation in
            Group {
                switch presentation {
                case .live(let liveRide):
                    LiveRideScreen(
                        viewModel: LiveRideViewModel(
                            tracker: liveRide.tracker, keepScreenOnPreference: dependencies.keepScreenOnPreference,
                            idleTimer: dependencies.idleTimer, session: liveRide.session,
                            directions: dependencies.directions),
                        onFinishRide: { Task { await dependencies.rideFinisher.finishRide(liveRide) } },
                        forceCheck: Self.forceCheck(liveRide))
                case .summary(let outcome):
                    RideSummaryView(
                        viewModel: RideSummaryViewModel(
                            outcome: outcome, uploader: dependencies.rideUploader,
                            decisionLog: dependencies.decisionLog),
                        onDone: closeSummary)
                }
            }
            .interactiveDismissDisabled()
        }
    }

    /// Debug builds get a Force Check on the dashboard; Release gets none (RULE-15).
    private static func forceCheck(_ liveRide: LiveRide) -> (() -> Void)? {
        #if DEBUG
        return { Task { await liveRide.session.forceNextCheck() } }
        #else
        return nil
        #endif
    }

    /// AC-85: Done closes the cover and shows Home, whatever was pushed when the ride started
    /// (Demo Mode, the corridor map).
    private func closeSummary() {
        dependencies.appRouter.popToHome()
        dependencies.rideCoordinator.dismissSummary()
    }

    private var readinessSheetPresented: Binding<Bool> {
        Binding(
            get: { dependencies.rideStartFlow.isReadinessSheetPresented },
            set: { dependencies.rideStartFlow.isReadinessSheetPresented = $0 })
    }

    /// The cover follows `RideCoordinator.presentation` (RULE-7). It can only be closed by the
    /// summary's Done, so the only write that reaches the setter is that dismissal.
    private var ridePresentation: Binding<RidePresentation?> {
        Binding(
            get: { dependencies.rideCoordinator.presentation },
            set: { if $0 == nil { closeSummary() } })
    }

    @ViewBuilder
    private func destination(for route: HomeRoute) -> some View {
        switch route {
        case .corridorMap:
            CorridorMapScreen(
                coordinator: dependencies.corridorImportCoordinator,
                onStartRide: { Task { await dependencies.rideStartFlow.requestStart() } })
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

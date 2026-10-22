import SwiftUI

@main
struct CyclingCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let configurationError: String?
    private let dependencies: AppDependencies

    init() {
        var configurationError: String?
        let configuration: BackendConfiguration
        do {
            configuration = try BackendConfiguration.load()
        } catch {
            // Construct inert dependencies, but show the configuration error instead of
            // starting network requests or resuming a ride against a wrong server.
            configuration = .local
            configurationError = error.localizedDescription
        }
        #if DEBUG
        // UI tests run offline on a stub backend, so the real configuration doesn't matter.
        let dependencies: AppDependencies
        if UITestFixtures.isEnabled {
            dependencies = UITestFixtures.makeDependencies()
            configurationError = nil
        } else {
            dependencies = AppDependencies.live(configuration: configuration)
        }
        #else
        let dependencies = AppDependencies.live(configuration: configuration)
        #endif
        self.configurationError = configurationError
        self.dependencies = dependencies
        appDelegate.appRouter = dependencies.appRouter
        appDelegate.rideCoordinator = dependencies.rideCoordinator
    }

    var body: some Scene {
        WindowGroup {
            if let configurationError {
                ContentUnavailableView(
                    "Backend configuration required", systemImage: "network",
                    description: Text(configurationError))
            } else {
                ContentView()
                    .environment(dependencies)
                    .task {
                        #if DEBUG
                        if UITestFixtures.isEnabled { await UITestFixtures.seed(dependencies) }
                        #endif
                        await dependencies.corridorImportCoordinator.resumePollingForBuildingRoutes()
                        await dependencies.makeRideResumer().resumeIfNeeded()
                        dependencies.appRouter.launchResumeFinished(
                            ridePhase: dependencies.rideCoordinator.phase)
                        #if DEBUG
                        if UITestFixtures.isEnabled { UITestFixtures.simulateNotificationTapIfRequested(appDelegate) }
                        #endif
                        await dependencies.makePendingRideUploadRetrier().retryPendingUploads()
                    }
            }
        }
    }
}

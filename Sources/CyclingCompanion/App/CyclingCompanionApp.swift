import SwiftUI

@main
struct CyclingCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let configurationError: String?
    private let dependencies: AppDependencies

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
        let dependencies = AppDependencies.live(configuration: configuration)
        self.dependencies = dependencies
        appDelegate.appRouter = dependencies.appRouter
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
                        await dependencies.makeRideResumer().resumeIfNeeded()
                        await dependencies.makePendingRideUploadRetrier().retryPendingUploads()
                    }
            }
        }
    }
}

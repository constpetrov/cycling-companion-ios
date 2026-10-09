import RoutePersistence
import UIKit

/// Minimal `AppDelegate` (RULE-8 in spec/rules.md) — the app's pure SwiftUI lifecycle has no
/// other way to read CoreLocation's background-relaunch launch option. On a location-
/// triggered relaunch, constructs a `RideTracker` and calls `resumeIfNeeded` so an in-progress
/// ride's checkpoint isn't silently lost. This milestone has no real navigation wiring
/// connecting that tracker to the live progress screen (spec.md); proving the relaunch path
/// actually reaches `resumeIfNeeded` is this task's own validation scope (task-4.3), not full
/// UI wiring — `resumeIfNeeded` itself locates the checkpoint by scanning the store for the
/// one unfinished ride (RULE-13), so the placeholder id/route this tracker is constructed with
/// don't need to match it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard launchOptions?[.location] != nil else {
            return true
        }
        Task {
            guard let fileURL = try? RideStore.defaultFileURL() else { return }
            let rideStore = RideStore(fileURL: fileURL)
            let tracker = await RideTracker(
                rideId: "", routeId: "", startTime: Date(), route: [], locationSource: CoreLocationSource(),
                sensorSource: NoSensorSource(), clock: SystemClock(), rideStore: rideStore)
            try? await tracker.resumeIfNeeded(from: rideStore)
        }
        return true
    }
}

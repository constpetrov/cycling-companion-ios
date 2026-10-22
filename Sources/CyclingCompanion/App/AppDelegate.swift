import RoutePersistence
import UIKit
import UserNotifications

/// Minimal `AppDelegate` (RULE-8 in spec/rules.md) — the app's pure SwiftUI lifecycle has no
/// other way to read CoreLocation's background-relaunch launch option. On a location-
/// triggered relaunch, constructs a `RideTracker` and calls `resumeIfNeeded` so an in-progress
/// ride's checkpoint isn't silently lost. This milestone has no real navigation wiring
/// connecting that tracker to the live progress screen (spec.md); proving the relaunch path
/// actually reaches `resumeIfNeeded` is this task's own validation scope (task-4.3), not full
/// UI wiring — `resumeIfNeeded` itself locates the checkpoint by scanning the store for the
/// one unfinished ride (RULE-13), so the placeholder id/route this tracker is constructed with
/// don't need to match it.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Settable (not injected via `init`) because `@UIApplicationDelegateAdaptor` constructs
    /// this instance before `CyclingCompanionApp`'s own `AppRouter` exists — the eventual
    /// app-wiring task sets this once, early, after constructing the shared router. `nil`
    /// until then; `userNotificationCenter(_:didReceive:...)` is a no-op without it.
    var appRouter: AppRouter?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

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

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// How a notification is shown while the app is in the foreground. During a ride the live
    /// screen is usually open, and without this iOS silently drops the banner, so the rider
    /// never sees the stop suggestion.
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundPresentationOptions)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationTap()
        completionHandler()
    }

    /// A notification tap needs no navigation of its own: an active ride is always on screen in
    /// the ride cover, and with no ride the app stays where it is rather than showing a
    /// placeholder (AC-76 in milestone 7's criteria.md). Routing the tapped stop into its sheet
    /// arrives with `StopLink` (task-4.6). Kept as a seam, directly testable without a real
    /// `UNNotificationResponse` (which has no public initializer).
    func handleNotificationTap() {}
}

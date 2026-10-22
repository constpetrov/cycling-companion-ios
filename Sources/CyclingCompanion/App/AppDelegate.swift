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
    /// Set alongside `appRouter`; a tap is routed according to the ride's phase.
    var rideCoordinator: RideCoordinator?

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
        handleNotificationTap(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }

    /// AC-71 to AC-76 (RULE-20): the tapped stop becomes a `StopLink` held by the router until the
    /// dashboard can open its sheet; with no ride to show it on, the app stays where it is. Pulled
    /// out of the delegate callback so it is testable without a real `UNNotificationResponse`,
    /// which has no public initializer.
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let appRouter, let link = StopLink(userInfo: userInfo) else { return }
        appRouter.handle(link, ridePhase: rideCoordinator?.phase ?? .idle)
    }
}

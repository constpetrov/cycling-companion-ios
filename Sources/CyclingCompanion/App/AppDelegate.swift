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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationTap()
        completionHandler()
    }

    /// AC-18/AC-19: unconditionally shows the live ride screen on any notification tap,
    /// regardless of which screen is currently showing — the same callback fires for both the
    /// already-running case and the terminated-then-relaunched case (iOS itself relaunches a
    /// terminated app and still delivers this). Never downgrades an already-resumed/started
    /// ride's real tracker back to the placeholder `nil` — if `.liveRide` already carries one,
    /// there's nothing to change. Pulled out of the delegate callback itself (which never reads
    /// `response` at all — RULE-10's "no `userInfo` inspection needed") so it's directly
    /// testable without constructing a real `UNNotificationResponse`, which has no public
    /// initializer.
    func handleNotificationTap() {
        if case .liveRide(.some) = appRouter?.currentScreen {
            // already showing a real ride — nothing to overwrite.
        } else {
            appRouter?.show(.liveRide(nil))
        }
    }
}

import Foundation

/// Start Ride through the readiness check (RULE-21 in milestone 7's rules.md, AC-86 to AC-92): with
/// everything in place the ride starts at once; otherwise the readiness sheet opens, and the ride
/// starts from there once location allows it. Demo rides don't come through here (AC-94).
@MainActor
@Observable
final class RideStartFlow {
    let readiness: ReadinessViewModel
    var isReadinessSheetPresented = false
    private let start: @MainActor () async -> Void

    init(readiness: ReadinessViewModel, start: @escaping @MainActor () async -> Void) {
        self.readiness = readiness
        self.start = start
    }

    /// Start Ride tapped on Home or the corridor map.
    func requestStart() async {
        await readiness.refresh()
        guard readiness.decision?.needsCheck == true else {
            await start()
            return
        }
        isReadinessSheetPresented = true
    }

    /// The sheet's start button — "Start ride", or "Start without suggestions" when notifications
    /// are missing. Ignored while location doesn't allow a ride (AC-90).
    func startFromSheet() async {
        await readiness.refresh()
        guard readiness.decision?.canStart == true else { return }
        isReadinessSheetPresented = false
        await start()
    }
}

/// Everything granted; for previews and UI tests, which must never show system permission prompts.
@MainActor
struct GrantedPermissions: PermissionStatusProviding {
    func current() async -> PermissionSnapshot {
        PermissionSnapshot(location: .always, preciseLocation: true, notifications: .authorized)
    }

    func requestLocationWhenInUse() async {}
    func requestLocationAlways() async {}
    func requestNotifications() async {}
    func openSettings() {}
}

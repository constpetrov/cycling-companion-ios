@preconcurrency import CoreLocation
import UIKit
import UserNotifications

enum LocationPermission: Equatable, Sendable {
    case notDetermined
    /// Denied or restricted: only Settings can change it.
    case denied
    case whenInUse
    case always
}

enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case denied
    /// Authorized, provisional or ephemeral — notifications will be posted.
    case authorized
}

struct PermissionSnapshot: Equatable, Sendable {
    var location: LocationPermission
    var preciseLocation: Bool
    var notifications: NotificationPermission
}

/// Reads and requests the permissions a ride needs (RULE-21 in milestone 7's rules.md). The only
/// place the app asks for location or notification permission.
@MainActor
protocol PermissionStatusProviding {
    func current() async -> PermissionSnapshot
    func requestLocationWhenInUse() async
    func requestLocationAlways() async
    func requestNotifications() async
    func openSettings()
}

/// The system's permissions.
@MainActor
final class SystemPermissions: NSObject, PermissionStatusProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationChange: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func current() async -> PermissionSnapshot {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return PermissionSnapshot(
            location: Self.location(manager.authorizationStatus),
            preciseLocation: manager.accuracyAuthorization == .fullAccuracy,
            notifications: Self.notifications(settings.authorizationStatus))
    }

    func requestLocationWhenInUse() async {
        await waitForAuthorizationChange { $0.requestWhenInUseAuthorization() }
    }

    func requestLocationAlways() async {
        await waitForAuthorizationChange { $0.requestAlwaysAuthorization() }
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// iOS reports the outcome through the delegate. If it doesn't prompt (already decided), the
    /// change may never come, so the wait is capped.
    private func waitForAuthorizationChange(_ request: (CLLocationManager) -> Void) async {
        await withCheckedContinuation { continuation in
            authorizationChange = continuation
            request(manager)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.resumeAuthorizationWait()
            }
        }
    }

    private func resumeAuthorizationWait() {
        authorizationChange?.resume()
        authorizationChange = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.resumeAuthorizationWait() }
    }

    private static func location(_ status: CLAuthorizationStatus) -> LocationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        default: .denied
        }
    }

    private static func notifications(_ status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        default: .denied
        }
    }
}

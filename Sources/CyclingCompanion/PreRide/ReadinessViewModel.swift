import Foundation

/// One line of the pre-ride readiness check.
struct ReadinessItem: Equatable, Identifiable {
    enum Kind: Equatable {
        case location
        case preciseLocation
        case notifications
    }

    enum Action: Equatable {
        /// iOS can still show its own prompt.
        case grant
        /// Already denied, or only changeable in Settings.
        case openSettings
    }

    let kind: Kind
    let title: String
    let detail: String
    let action: Action

    var id: Kind { kind }
}

/// What the readiness check decides for a permission snapshot (AC-86 to AC-92). Pure, so every
/// combination is unit-tested.
struct ReadinessDecision: Equatable {
    /// AC-86/AC-87: false only when everything is already in place, so Start goes straight on.
    let needsCheck: Bool
    /// The missing items, in the order shown.
    let items: [ReadinessItem]
    /// AC-90/AC-91: at least When-In-Use location.
    let canStart: Bool
    /// AC-91: location only while the app is open — tracking stops when the phone locks.
    let warnsTrackingStopsWhenLocked: Bool
    /// AC-92: notifications are missing, but the ride can start without suggestions.
    let offersStartWithoutSuggestions: Bool

    static func evaluate(_ snapshot: PermissionSnapshot) -> ReadinessDecision {
        var items: [ReadinessItem] = []
        switch snapshot.location {
        case .notDetermined:
            items.append(ReadinessItem(
                kind: .location, title: "Location",
                detail: "Needed to track your ride against the route.", action: .grant))
        case .denied:
            items.append(ReadinessItem(
                kind: .location, title: "Location is off",
                detail: "Turn on location for Cycling Companion in Settings to start a ride.", action: .openSettings))
        case .whenInUse:
            items.append(ReadinessItem(
                kind: .location, title: "Allow location Always",
                detail: "With \"While Using\" only, tracking stops when the phone locks.", action: .grant))
        case .always:
            break
        }
        if snapshot.location != .notDetermined, snapshot.location != .denied, !snapshot.preciseLocation {
            items.append(ReadinessItem(
                kind: .preciseLocation, title: "Precise location is off",
                detail: "Without it, progress along the route is unreliable.", action: .openSettings))
        }
        switch snapshot.notifications {
        case .notDetermined:
            items.append(ReadinessItem(
                kind: .notifications, title: "Notifications",
                detail: "Stop suggestions arrive as notifications while you ride.", action: .grant))
        case .denied:
            items.append(ReadinessItem(
                kind: .notifications, title: "Notifications are off",
                detail: "Turn them on in Settings to get stop suggestions.", action: .openSettings))
        case .authorized:
            break
        }

        let canStart = snapshot.location == .whenInUse || snapshot.location == .always
        return ReadinessDecision(
            needsCheck: !items.isEmpty, items: items, canStart: canStart,
            warnsTrackingStopsWhenLocked: snapshot.location == .whenInUse,
            offersStartWithoutSuggestions: canStart && snapshot.notifications != .authorized)
    }
}

/// The readiness check's state (RULE-9/RULE-21 in milestone 7's rules.md): the current permission
/// snapshot, refreshed whenever the app becomes active (e.g. back from Settings), and the actions.
@MainActor
@Observable
final class ReadinessViewModel {
    private let permissions: PermissionStatusProviding
    private(set) var decision: ReadinessDecision?

    init(permissions: PermissionStatusProviding) {
        self.permissions = permissions
    }

    /// AC-93.
    func refresh() async {
        decision = ReadinessDecision.evaluate(await permissions.current())
    }

    /// Runs `item`'s action, then re-reads the permissions. For location, When In Use is asked for
    /// first and Always only once When In Use is granted (iOS's two-step flow).
    func perform(_ item: ReadinessItem) async {
        switch (item.kind, item.action) {
        case (_, .openSettings):
            permissions.openSettings()
        case (.location, .grant):
            let snapshot = await permissions.current()
            if snapshot.location == .notDetermined {
                await permissions.requestLocationWhenInUse()
            } else {
                await permissions.requestLocationAlways()
            }
        case (.notifications, .grant):
            await permissions.requestNotifications()
        case (.preciseLocation, .grant):
            permissions.openSettings()
        }
        await refresh()
    }
}

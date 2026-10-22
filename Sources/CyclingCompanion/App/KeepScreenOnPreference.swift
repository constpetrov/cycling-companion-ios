import Foundation
import UIKit

/// The rider's keep-screen-on choice (RULE-13 in milestone 7's rules.md), remembered across rides.
@MainActor
protocol KeepScreenOnPreference: AnyObject {
    var isEnabled: Bool { get set }
}

/// Production storage: `UserDefaults` key `keepScreenOn`, off unless the rider turned it on.
@MainActor
final class UserDefaultsKeepScreenOnPreference: KeepScreenOnPreference {
    private static let key = "keepScreenOn"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// Not persisted; for previews and tests.
@MainActor
final class InMemoryKeepScreenOnPreference: KeepScreenOnPreference {
    var isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }
}

/// Switches the device's auto-lock off and on (RULE-13). One owner — `LiveRideViewModel` — so
/// "restored after the ride" is checkable with a fake.
@MainActor
protocol IdleTimerControlling {
    func setIdleTimerDisabled(_ disabled: Bool)
}

@MainActor
struct ApplicationIdleTimer: IdleTimerControlling {
    func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

/// Does nothing; for previews and tests that don't care about auto-lock.
@MainActor
struct NoIdleTimer: IdleTimerControlling {
    func setIdleTimerDisabled(_ disabled: Bool) {}
}

import Foundation

/// The last signed-in rider, remembered across launches and sessions (milestone 10, RA-24, RULE-40).
/// Not secret: it decides whether local data belongs to the rider signing in, and gives Settings the
/// email. Survives a session that ended, cleared only with the local data.
struct AccountMemory {
    private let defaults: UserDefaults

    static let riderIdKey = "auth.lastRiderId"
    static let emailKey = "auth.lastEmail"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var riderId: String? {
        defaults.string(forKey: Self.riderIdKey)
    }

    var email: String? {
        defaults.string(forKey: Self.emailKey)
    }

    func remember(riderId: String, email: String) {
        defaults.set(riderId, forKey: Self.riderIdKey)
        defaults.set(email, forKey: Self.emailKey)
    }

    func forget() {
        defaults.removeObject(forKey: Self.riderIdKey)
        defaults.removeObject(forKey: Self.emailKey)
    }
}

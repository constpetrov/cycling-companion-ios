import Foundation

/// RULE-36 in milestone 10's rules.md: the Keychain survives deleting the app and UserDefaults
/// doesn't, so a missing flag marks a fresh install. Its leftover refresh token is deleted before
/// anything signs in with it, so a reinstall (or the phone's next owner) starts signed out.
enum FirstLaunchCheck {
    static let defaultsKey = "auth.hasLaunchedBefore"

    /// Run once at launch, before any network call.
    static func run(defaults: UserDefaults, tokenStore: TokenStore) {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        // A locked device leaves the old token in place for now; the flag stays unset, so the next
        // launch tries again.
        guard (try? tokenStore.delete()) != nil else { return }
        defaults.set(true, forKey: defaultsKey)
    }
}

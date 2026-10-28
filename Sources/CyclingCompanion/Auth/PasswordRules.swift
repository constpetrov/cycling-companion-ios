import Foundation

/// RULE-4 in milestone 10's rules.md: a new password is 10 to 128 Unicode code points, counted as the
/// backend counts them (`unicodeScalars`, not `count`, which would see an emoji as one even when
/// it is several scalars). Checked before any request is sent (AC-136 to AC-139).
enum PasswordRules {
    static let minLength = 10
    static let maxLength = 128

    /// The problem with `password`, worded like the backend's message, or `nil` when it is fine.
    static func problem(_ password: String) -> String? {
        let length = password.unicodeScalars.count
        if length < minLength { return "Password must be at least \(minLength) characters" }
        if length > maxLength { return "Password must be at most \(maxLength) characters" }
        return nil
    }
}

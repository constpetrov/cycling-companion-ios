import Foundation
import Observation

/// The Settings account section's state (milestone 10, RULE-41): the email, change password, sign
/// out with its warning, and delete account behind the password.
@MainActor
@Observable
final class AccountSettingsModel {
    var currentPassword = ""
    var newPassword = ""
    var deletePassword = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var passwordChanged = false
    /// Set by `prepareSignOut()`; the view shows the confirmation while it isn't `nil`.
    var signOutWarning: String?
    var isDeletePromptPresented = false

    private let actions: AccountActions

    init(actions: AccountActions) {
        self.actions = actions
    }

    var email: String {
        actions.email ?? "—"
    }

    /// AC-134.
    var canDeleteAccount: Bool {
        !actions.isRideInProgress
    }

    var canChangePassword: Bool {
        !isWorking && !currentPassword.isEmpty && !newPassword.isEmpty
    }

    /// AC-126: checked locally first (RULE-4); the phone stays signed in.
    func changePassword() async {
        guard canChangePassword else { return }
        passwordChanged = false
        if let problem = PasswordRules.problem(newPassword) {
            errorMessage = problem
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await actions.changePassword(current: currentPassword, new: newPassword)
            currentPassword = ""
            newPassword = ""
            passwordChanged = true
        } catch {
            errorMessage = error.message
        }
    }

    /// AC-127: the confirmation names the rides that aren't uploaded yet.
    func prepareSignOut() async {
        let rides = await actions.unuploadedRideCount()
        let lost = rides == 0 ? "" : rides == 1 ? " 1 ride isn't uploaded yet and will be lost."
            : " \(rides) rides aren't uploaded yet and will be lost."
        signOutWarning = "Signing out deletes your routes and rides from this phone.\(lost)"
    }

    func signOut() async {
        signOutWarning = nil
        isWorking = true
        defer { isWorking = false }
        await actions.signOut()
    }

    func requestDelete() {
        guard canDeleteAccount else { return }
        deletePassword = ""
        errorMessage = nil
        isDeletePromptPresented = true
    }

    /// AC-133: sent only after the password is entered and confirmed.
    func deleteAccount() async {
        guard canDeleteAccount, !deletePassword.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await actions.deleteAccount(password: deletePassword)
        } catch {
            errorMessage = error.message
        }
        deletePassword = ""
    }
}

import Foundation
import Observation

/// The sign-in, sign-up and reset forms' state (milestone 10, RULE-42). One model, three modes, so
/// switching between them keeps the email the rider already typed.
@MainActor
@Observable
final class AuthFlowModel {
    enum Mode: Equatable {
        case signIn
        case signUp
        case reset
    }

    var mode: Mode = .signIn {
        didSet { errorMessage = nil }
    }
    var email = ""
    var password = ""
    var inviteCode = ""
    var resetCode = ""
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?
    /// RULE-40: a different rider signed in while the last one's data is still here.
    var pendingSwitch: AccountActions.PendingSwitch?

    private let actions: AccountActions

    init(actions: AccountActions) {
        self.actions = actions
    }

    var canSubmit: Bool {
        guard !isSubmitting, !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return false }
        switch mode {
        case .signIn: return true
        case .signUp: return !inviteCode.trimmingCharacters(in: .whitespaces).isEmpty
        case .reset: return !resetCode.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Sends the form. A new password is length-checked first and nothing is sent when it fails
    /// (RULE-4); a refusal shows the backend's message and keeps what was typed (AC-112, AC-113).
    func submit() async {
        guard canSubmit else { return }
        if mode != .signIn, let problem = PasswordRules.problem(password) {
            errorMessage = problem
            return
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let result: AccountActions.StartResult
            switch mode {
            case .signIn: result = try await actions.signIn(email: email, password: password)
            case .signUp: result = try await actions.signUp(email: email, password: password, inviteCode: inviteCode)
            case .reset: result = try await actions.reset(email: email, code: resetCode, newPassword: password)
            }
            if case let .confirmSwitch(pending) = result {
                pendingSwitch = pending
            } else {
                password = ""
            }
        } catch {
            errorMessage = error.message
        }
    }

    /// The text of the account-switch confirmation (AC-131).
    var switchWarning: String {
        guard let pendingSwitch else { return "" }
        let rides = pendingSwitch.unuploadedRides
        let lost = rides == 0 ? "" : rides == 1 ? " 1 ride not uploaded yet will be lost." : " \(rides) rides not uploaded yet will be lost."
        return "This phone still has another rider's routes and rides. Signing in deletes them from this phone.\(lost)"
    }

    /// AC-131: erase the last rider's data and sign in.
    func confirmSwitch() async {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await actions.confirm(pending)
            password = ""
        } catch {
            errorMessage = error.message
        }
    }

    /// AC-132: keep the data; the new rider stays signed out.
    func declineSwitch() async {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        await actions.decline(pending)
    }
}

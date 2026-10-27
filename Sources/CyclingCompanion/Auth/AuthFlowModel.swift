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
            switch mode {
            case .signIn: try await actions.signIn(email: email, password: password)
            case .signUp: try await actions.signUp(email: email, password: password, inviteCode: inviteCode)
            case .reset: try await actions.reset(email: email, code: resetCode, newPassword: password)
            }
            password = ""
        } catch {
            errorMessage = error.message
        }
    }
}

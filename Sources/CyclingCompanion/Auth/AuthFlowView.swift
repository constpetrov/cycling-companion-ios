import SwiftUI

/// The sign-in, sign-up and reset screens shown without a session (milestone 10, RULE-37, RULE-42).
/// AutoFill hints are the standard ones; saving to iCloud Keychain under our domain waits for
/// Associated Domains (spec A-5).
struct AuthFlowView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var model: AuthFlowModel?

    var body: some View {
        NavigationStack {
            if let model {
                AuthForm(model: model, endedMessage: dependencies.sessionState.endedMessage)
            }
        }
        .onAppear {
            if model == nil { model = AuthFlowModel(actions: dependencies.accountActions) }
        }
    }
}

private struct AuthForm: View {
    @Bindable var model: AuthFlowModel
    let endedMessage: String?

    var body: some View {
        Form {
            if model.mode == .signIn, let endedMessage {
                Section {
                    Label(endedMessage, systemImage: "exclamationmark.circle")
                        .accessibilityIdentifier("auth.endedMessage")
                }
            }
            Section {
                TextField("Email", text: $model.email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("auth.email")
                if model.mode == .reset {
                    TextField("Reset code", text: $model.resetCode)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("auth.resetCode")
                }
                SecureField(model.mode == .signIn ? "Password" : "New password", text: $model.password)
                    .textContentType(model.mode == .signIn ? .password : .newPassword)
                    // A fresh field per form: iOS keeps an AutoFill strong-password suggestion in a
                    // reused field even after its content type changes.
                    .id(model.mode)
                    .accessibilityIdentifier("auth.password")
                if model.mode == .signUp {
                    TextField("Invite code", text: $model.inviteCode)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("auth.inviteCode")
                }
            } footer: {
                if model.mode != .signIn {
                    Text("At least \(PasswordRules.minLength) characters.")
                }
            }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("auth.error")
                }
            }

            Section {
                Button {
                    Task { await model.submit() }
                } label: {
                    HStack {
                        Text(submitTitle)
                        if model.isSubmitting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("auth.submit")
            }

            Section {
                switch model.mode {
                case .signIn:
                    Button("Create an account with an invite code") { model.mode = .signUp }
                        .accessibilityIdentifier("auth.toSignUp")
                    Button("Forgot password?") { model.mode = .reset }
                        .accessibilityIdentifier("auth.toReset")
                case .signUp, .reset:
                    Button("Back to sign in") { model.mode = .signIn }
                        .accessibilityIdentifier("auth.toSignIn")
                }
            } footer: {
                if model.mode == .reset {
                    Text("Ask the person who invited you for a reset code. It is valid for 24 hours.")
                }
            }
        }
        .navigationTitle(title)
        .onSubmit { Task { await model.submit() } }
        .confirmationDialog(
            "Sign in as a different rider?",
            // Both buttons clear `pendingSwitch`; dismissing the dialog runs the Cancel button's action.
            isPresented: Binding(get: { model.pendingSwitch != nil }, set: { _ in }),
            titleVisibility: .visible
        ) {
            Button("Delete and sign in", role: .destructive) { Task { await model.confirmSwitch() } }
                .accessibilityIdentifier("auth.confirmSwitch")
            Button("Cancel", role: .cancel) { Task { await model.declineSwitch() } }
        } message: {
            Text(model.switchWarning)
        }
    }

    private var title: String {
        switch model.mode {
        case .signIn: "Sign in"
        case .signUp: "Create account"
        case .reset: "Reset password"
        }
    }

    private var submitTitle: String {
        switch model.mode {
        case .signIn: "Sign in"
        case .signUp: "Create account"
        case .reset: "Set new password and sign in"
        }
    }
}

#if DEBUG
#Preview {
    AuthFlowView()
        .environment(AppDependencies.preview)
}
#endif

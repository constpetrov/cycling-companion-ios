import SwiftUI

/// Settings → Account (milestone 10, RULE-41): the email, Change password, Sign out, and Delete
/// account, which is hidden during a ride and asks for the password.
struct AccountSection: View {
    @Bindable var model: AccountSettingsModel

    var body: some View {
        Section {
            LabeledContent("Email", value: model.email)
                .accessibilityIdentifier("account.email")
            NavigationLink("Change password") {
                ChangePasswordView(model: model)
            }
            .accessibilityIdentifier("account.changePassword")
            Button("Sign out") {
                Task { await model.prepareSignOut() }
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("account.signOut")
            if model.canDeleteAccount {
                Button("Delete account", role: .destructive) {
                    model.requestDelete()
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("account.delete")
            }
            if let error = model.errorMessage, !model.isDeletePromptPresented {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("account.error")
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Deleting your account removes it and all its rides from the server and this phone.")
        }
        .confirmationDialog(
            "Sign out?", isPresented: Binding(get: { model.signOutWarning != nil }, set: { if !$0 { model.signOutWarning = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                .accessibilityIdentifier("account.confirmSignOut")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.signOutWarning ?? "")
        }
        .alert("Delete account?", isPresented: $model.isDeletePromptPresented) {
            SecureField("Password", text: $model.deletePassword)
                .textContentType(.password)
            Button("Delete", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter your password. Your account, its routes and rides are deleted for good.")
        }
    }
}

/// Current and new password; on success the phone stays signed in (AC-126).
private struct ChangePasswordView: View {
    @Bindable var model: AccountSettingsModel

    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $model.currentPassword)
                    .textContentType(.password)
                    .accessibilityIdentifier("account.currentPassword")
                SecureField("New password", text: $model.newPassword)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("account.newPassword")
            } footer: {
                Text("At least \(PasswordRules.minLength) characters. Your other phones are signed out.")
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
            if model.passwordChanged {
                Section {
                    Label("Password changed", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("account.passwordChanged")
                }
            }
            Section {
                Button("Change password") {
                    Task { await model.changePassword() }
                }
                .disabled(!model.canChangePassword)
            }
        }
        .navigationTitle("Change password")
    }
}

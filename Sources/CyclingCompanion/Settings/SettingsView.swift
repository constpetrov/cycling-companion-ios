import SwiftUI

/// Settings, pushed from Home: the account (milestone 10), and which stop types the maps show and
/// the ride suggests.
struct SettingsView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var account: AccountSettingsModel?

    var body: some View {
        let settings = dependencies.stopTypeSettings
        Form {
            if let account {
                AccountSection(model: account)
            }
            Section {
                ForEach(StopType.allCases) { type in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(type) },
                        set: { settings.setEnabled($0, for: type) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.title)
                                Text(type.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: type.systemImage)
                        }
                    }
                    .accessibilityIdentifier("stopType.\(type.rawValue)")
                }
            } header: {
                Text("Stops")
            } footer: {
                Text(settings.allDisabled
                    ? "Every stop type is off, so the app won't show or suggest any stops."
                    : "Types that are off aren't shown on the maps or suggested during a ride.")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            if account == nil { account = AccountSettingsModel(actions: dependencies.accountActions) }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SettingsView()
    }
    .environment(AppDependencies.preview)
}
#endif

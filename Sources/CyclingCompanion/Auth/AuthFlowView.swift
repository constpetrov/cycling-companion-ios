import SwiftUI

/// The sign-in, sign-up and reset screens shown without a session (milestone 10, RULE-37, RULE-42).
struct AuthFlowView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        ContentUnavailableView(
            "Sign in required", systemImage: "person.crop.circle",
            description: Text(dependencies.sessionState.endedMessage ?? "Sign in to continue."))
    }
}

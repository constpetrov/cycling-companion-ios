import SwiftUI

/// The stop search state shared by Home's route card and the corridor map (milestone 8,
/// RULE-19/RULE-20): the status, Retry with its in-flight spinner and last error, and the coverage
/// message. Texts wrap so they stay whole at the largest text sizes (AC-58).
struct CorridorStatusRow: View {
    let state: CorridorState
    let coverageText: String?
    let retryInFlight: Bool
    let retryError: CorridorActionError?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // Only the status is combined; Retry stays its own element so VoiceOver can activate it.
                HStack {
                    if state == .finding {
                        ProgressView()
                            .accessibilityHidden(true)  // the message already says it's searching
                    }
                    Text(state.message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                if state.offersRetry {
                    Button(action: onRetry) {
                        Group {
                            if retryInFlight {
                                ProgressView()
                            } else {
                                Text("Retry")
                            }
                        }
                        // The frame is inside the label so the whole 44 pt area is tappable.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(retryInFlight)
                    .accessibilityLabel(retryInFlight ? "Retrying" : "Retry")
                }
            }
            if state.offersRetry, let retryError {
                // Icon plus primary-colour text, like the app's other warnings (red text fails contrast).
                WarningLabel(retryError.message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Retry failed: \(retryError.message)")
            }
            if let coverageText {
                Label {
                    Text(coverageText)
                } icon: {
                    Image(systemName: "map")
                        .accessibilityHidden(true)  // decorative; VoiceOver would read "Show Map"
                }
                    .accessibilityElement(children: .combine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("coverageMessage")
            }
        }
        // VoiceOver focus stays on Retry, so say what happened (only on changes, not on first render).
        .onChange(of: retryInFlight) { _, inFlight in
            if inFlight { AccessibilityNotification.Announcement("Retrying").post() }
        }
        .onChange(of: retryError) { _, error in
            if let error { AccessibilityNotification.Announcement("Retry failed: \(error.message)").post() }
        }
    }
}

extension CorridorActionError {
    var message: String {
        switch self {
        case .noConnection: "No connection"
        case .server: "Server problem — try again"
        }
    }
}

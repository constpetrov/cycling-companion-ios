import SwiftUI

/// The pre-ride readiness sheet (AC-87 to AC-93): each missing permission with Grant or Open
/// Settings, the When-In-Use warning, and the start button once location allows a ride.
struct ReadinessSheet: View {
    let flow: RideStartFlow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("A few things before you ride")
                            .font(.title2.bold())
                        Spacer()
                        // Plain primary-coloured text, in the content rather than the toolbar: both the
                        // glass toolbar button and a tinted bordered one failed the contrast audit.
                        Button("Cancel", role: .cancel) { dismiss() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .font(.body.weight(.semibold))
                    }
                    if let decision = flow.readiness.decision {
                        ForEach(decision.items) { item in
                            itemRow(item)
                        }
                        if decision.warnsTrackingStopsWhenLocked {
                            WarningLabel("With location only while using the app, tracking stops when your phone locks. Keep the screen on, or allow Always.")
                            .font(.subheadline)
                        }
                        Button {
                            Task { await flow.startFromSheet() }
                        } label: {
                            Text(decision.offersStartWithoutSuggestions ? "Start without suggestions" : "Start ride")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!decision.canStart)
                        if !decision.canStart {
                            Text("Location is needed to start a ride.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
        }
        .task { await flow.readiness.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await flow.readiness.refresh() } }  // back from Settings (AC-93)
        }
    }

    private func itemRow(_ item: ReadinessItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
            Text(item.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(item.action == .grant ? "Allow" : "Open Settings") {
                Task { await flow.readiness.perform(item) }
            }
            .buttonStyle(.bordered)
                    .tint(.primary)  // blue or red text on the grey fill fails the contrast audit
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

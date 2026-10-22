import SwiftUI

/// The finished ride's summary, shown in the ride cover after Finish (RULE-1/RULE-7/RULE-22 in
/// milestone 7's rules.md): figures, upload status with Retry now, and Done.
struct RideSummaryView: View {
    let viewModel: RideSummaryViewModel
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(viewModel.savedRide == nil ? "Ride not saved" : "Ride complete")
                    .font(.largeTitle.bold())

                if let message = viewModel.notSavedMessage {
                    WarningLabel(message)
                } else {
                    figures
                    uploadStatus
                }

                Button(action: onDone) {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private var figures: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            SummaryRow(label: "Distance", value: viewModel.distanceText ?? "—")
            SummaryRow(label: "Moving time", value: viewModel.movingTimeText ?? "—")
            SummaryRow(label: "Average speed", value: viewModel.averageSpeedText ?? "—")
            SummaryRow(label: "Stops taken", value: viewModel.stopsTaken.map(String.init) ?? "—")
            SummaryRow(label: "Suggestions", value: viewModel.suggestionsText)
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        if let status = viewModel.uploadStatusText {
            HStack {
                Label(status, systemImage: viewModel.showsRetryNow ? "icloud.slash" : "icloud.and.arrow.up")
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.showsRetryNow {
                    Button("Retry now") { Task { await viewModel.retryNow() } }
                }
            }
        }
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

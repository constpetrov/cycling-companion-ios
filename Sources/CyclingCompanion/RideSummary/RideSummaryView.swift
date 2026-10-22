import SwiftUI

/// The finished ride's summary, shown in the ride cover after Finish (RULE-1/RULE-7 in milestone
/// 7's rules.md). Minimal for now — the outcome and Done; distance, time, suggestions and upload
/// status arrive with task-3.3.
struct RideSummaryView: View {
    let outcome: FinishOutcome
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch outcome {
            case .saved:
                Text("Ride saved")
                    .font(.title2)
            case .notSaved:
                Text("Couldn't save this ride — it will resume next time you open the app")
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

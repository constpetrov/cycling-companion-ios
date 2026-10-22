import SwiftUI

/// The dashboard's stop-suggestion card (AC-47, AC-54): stop, distance ahead, detour and the
/// advisor's message, or "Heading to …" once accepted. Tapping it opens the stop sheet.
struct SuggestionCardView: View {
    let suggestion: ApprovedSuggestion
    let isHeadingTo: Bool
    let distanceAhead: String
    let detour: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isHeadingTo ? "location.north.circle.fill" : "cup.and.saucer.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isHeadingTo ? "Heading to \(title)" : title)
                        .font(.headline)
                    Text("\(distanceAhead) ahead · \(detour) off route")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !isHeadingTo, let message = suggestion.message, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the stop's details and actions")
    }

    private var title: String {
        suggestion.name ?? LiveRideViewModel.typeLabel(suggestion.type)
    }
}

/// The half-height stop sheet (AC-49, AC-50, AC-53, AC-55, AC-57, AC-73): details plus Directions,
/// and Accept / Decline for a stop that was suggested this ride. Swiping it away records nothing.
struct StopSheetView: View {
    let item: StopSheetItem
    let distanceAhead: String
    let detour: String
    let onDirections: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.suggestion.name ?? LiveRideViewModel.typeLabel(item.suggestion.type))
                    .font(.title2.bold())
                Text("\(LiveRideViewModel.typeLabel(item.suggestion.type)) · \(distanceAhead) ahead · \(detour) off route")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let message = item.suggestion.message, !message.isEmpty {
                    Text(message)
                        .font(.body)
                }
            }
            Button(action: onDirections) {
                Label("Directions", systemImage: "bicycle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if item.offersAnswers {
                HStack(spacing: 12) {
                    Button(action: onAccept) {
                        Label("Accept", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Button(role: .destructive, action: onDecline) {
                        Label("Decline", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

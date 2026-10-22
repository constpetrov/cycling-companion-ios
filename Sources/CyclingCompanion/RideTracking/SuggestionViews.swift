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
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isHeadingTo ? "Heading to \(title)" : title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(distanceAhead) ahead · \(detour) off route")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isHeadingTo, let message = suggestion.message, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashboardPanel.background, in: RoundedRectangle(cornerRadius: 16))
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
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.suggestion.name ?? LiveRideViewModel.typeLabel(item.suggestion.type))
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(LiveRideViewModel.typeLabel(item.suggestion.type)) · \(distanceAhead) ahead · \(detour) off route")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = item.suggestion.message, !message.isEmpty {
                    Text(message)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onDirections) {
                SheetButtonLabel(title: "Directions", systemImage: "bicycle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if item.offersAnswers {
                // Stacked full width (easier with gloves; the side-by-side row clipped Decline).
                VStack(spacing: 12) {
                    Button(action: onAccept) {
                        SheetButtonLabel(title: "Accept", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)  // blue or red text on the grey fill fails the contrast audit
                    .controlSize(.large)
                    Button(action: onDecline) {
                        SheetButtonLabel(title: "Decline", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)  // blue or red text on the grey fill fails the contrast audit
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        }
        // Content that fits doesn't scroll or bounce, so it always sits at the top.
        .scrollBounceBehavior(.basedOnSize)
        // Half height by default (spec decision 8); pull up for the whole sheet.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Opaque: the translucent sheet over the map failed the contrast audit on its buttons.
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}

/// A full-width sheet button label whose text wraps rather than clips (the audit flagged a `Label`
/// stretched with `.frame(maxWidth:)` as clipped).
private struct SheetButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

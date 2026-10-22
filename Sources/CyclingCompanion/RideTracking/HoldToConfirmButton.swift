import SwiftUI

/// The hold-to-confirm state machine (RULE-14 in milestone 7's rules.md), kept apart from the
/// gesture so it can be unit-tested. The gesture reports pressing changes and, after
/// `holdDuration` of continuous pressing, that the threshold was reached.
struct HoldToConfirmState: Equatable {
    /// AC-39 to AC-41: the single hold duration.
    static let holdDuration: TimeInterval = 1.5

    private(set) var isPressing = false
    private(set) var isCompleted = false

    mutating func pressingChanged(_ pressing: Bool) {
        guard !isCompleted else { return }
        isPressing = pressing
    }

    /// Returns `true` exactly once — the first time the hold completes.
    mutating func holdReachedThreshold() -> Bool {
        guard !isCompleted else { return false }
        isCompleted = true
        isPressing = false
        return true
    }
}

/// A large control that confirms only after being held for `HoldToConfirmState.holdDuration`, with
/// a progress ring while held (AC-39 to AC-42). VoiceOver users get a named action that asks for
/// confirmation in a dialog instead (AC-43, AC-44).
struct HoldToConfirmButton: View {
    let title: String
    let accessibilityActionName: String
    let confirmationTitle: String
    let onConfirm: () -> Void

    @State private var state = HoldToConfirmState()
    @State private var progress: Double = 0
    @State private var isConfirmationPresented = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(.red.opacity(0.15))
            Capsule()
                .trim(from: 0, to: progress)
                .stroke(.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            Text(state.isPressing ? "Keep holding…" : title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.vertical, 18)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Capsule())
        .onLongPressGesture(
            minimumDuration: HoldToConfirmState.holdDuration, maximumDistance: 40,
            perform: {
                if state.holdReachedThreshold() {
                    progress = 1
                    onConfirm()
                }
            },
            onPressingChanged: { pressing in
                state.pressingChanged(pressing)
                guard !state.isCompleted else { return }
                if pressing {
                    withAnimation(.linear(duration: HoldToConfirmState.holdDuration)) { progress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Hold for \(HoldToConfirmState.holdDuration.formatted()) seconds")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: accessibilityActionName) { isConfirmationPresented = true }
        .confirmationDialog(confirmationTitle, isPresented: $isConfirmationPresented, titleVisibility: .visible) {
            Button(accessibilityActionName, role: .destructive) {
                if state.holdReachedThreshold() { onConfirm() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

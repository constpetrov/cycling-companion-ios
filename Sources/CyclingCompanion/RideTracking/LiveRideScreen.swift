import SwiftUI

/// The live ride dashboard (RULE-9/RULE-11 in milestone 7's rules.md): a full-screen map with the
/// ride's metrics and status badges on top, and keep-screen-on plus hold-to-finish at the bottom.
/// Shown inside the ride cover while a ride is active.
struct LiveRideScreen: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: LiveRideViewModel
    let onFinishRide: () -> Void
    /// Debug only: asks the advisor for a decision now instead of waiting out the cadence.
    let forceCheck: (() -> Void)?

    init(viewModel: LiveRideViewModel, onFinishRide: @escaping () -> Void, forceCheck: (() -> Void)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onFinishRide = onFinishRide
        self.forceCheck = forceCheck
    }

    var body: some View {
        LiveRideMapView(viewModel: viewModel)
            .ignoresSafeArea()
            .safeAreaInset(edge: .top) { metricsStrip }
            .safeAreaInset(edge: .bottom) { controls }
            .task {
                await viewModel.loadRoute(from: dependencies.routeStore)
                await viewModel.monitorGPS()
            }
            .task { await viewModel.listenForSuggestions() }
            .sheet(item: $viewModel.stopSheet) { item in
                StopSheetView(
                    item: item, distanceAhead: viewModel.distanceAheadText(for: item.suggestion),
                    detour: viewModel.detourText(for: item.suggestion),
                    onDirections: { Task { await viewModel.openDirections(for: item) } },
                    onAccept: { Task { await viewModel.accept(item) } },
                    onDecline: { Task { await viewModel.decline(item) } })
            }
            .onAppear { viewModel.dashboardDidAppear() }
            .onDisappear { viewModel.dashboardDidDisappear() }
    }

    private var metricsStrip: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                MetricTile(label: "Remaining", value: viewModel.distanceRemainingText)
                MetricTile(label: "Arrive", value: viewModel.arrivalTimeText ?? "—")
                MetricTile(label: "Speed", value: viewModel.speedText ?? "—")
            }
            HStack(spacing: 8) {
                if viewModel.isOffRoute {
                    StatusBadge(text: "Off route", systemImage: "arrow.uturn.left", tint: .orange)
                }
                if viewModel.isGPSLost {
                    StatusBadge(text: "No GPS", systemImage: "location.slash", tint: .red)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let suggestion = viewModel.currentSuggestion {
                SuggestionCardView(
                    suggestion: suggestion, isHeadingTo: viewModel.isHeadingToCurrent,
                    distanceAhead: viewModel.distanceAheadText(for: suggestion),
                    detour: viewModel.detourText(for: suggestion),
                    onTap: viewModel.openSheetForCurrentSuggestion)
            }
            #if DEBUG
            if let forceCheck {
                Button("Force Check", action: forceCheck)
                    .font(.footnote)
                    .accessibilityIdentifier("dashboard.forceCheck")
            }
            #endif
            Toggle(
                "Keep screen on",
                isOn: Binding(get: { viewModel.keepScreenOn }, set: { viewModel.setKeepScreenOn($0) }))
            HoldToConfirmButton(
                title: "Hold to finish", accessibilityActionName: "Finish ride",
                confirmationTitle: "Finish this ride?",
                onConfirm: {
                    viewModel.dashboardDidDisappear()
                    onFinishRide()
                })
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

/// One dashboard metric: a small label over a large value, read by VoiceOver as one element.
private struct MetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
    }
}

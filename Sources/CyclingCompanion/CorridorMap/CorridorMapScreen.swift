import RoutePersistence
import SwiftUI

/// The corridor map (RULE-13/RULE-25): the stored route and its stops, the stop search state with
/// Retry, and Start Ride, which is never disabled by the stop search (AC-114).
struct CorridorMapScreen: View {
    @State private var viewModel: CorridorMapViewModel
    let onStartRide: () -> Void

    init(viewModel: CorridorMapViewModel, onStartRide: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onStartRide = onStartRide
    }

    var startRideIsEnabled: Bool { viewModel.startRideIsEnabled }

    var body: some View {
        VStack(spacing: 12) {
            CorridorMapView(points: viewModel.route?.points ?? [], pois: viewModel.route?.pois ?? [])
            if let state = viewModel.state {
                CorridorStatusRow(
                    state: state, coverageText: viewModel.coverageText, retryInFlight: viewModel.retryInFlight,
                    retryError: viewModel.retryError, onRetry: { Task { await viewModel.retry() } })
                    .padding(.horizontal)
            }
            Button("Start Ride", action: onStartRide)
                .buttonStyle(.borderedProminent)
                .disabled(!startRideIsEnabled)
                .padding(.bottom)
        }
        .navigationTitle("Route")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .onChange(of: viewModel.storeRevision) {
            Task { await viewModel.reload() }
        }
        .onChange(of: viewModel.isPolling) { _, polling in
            if !polling { Task { await viewModel.reload() } }
        }
    }
}

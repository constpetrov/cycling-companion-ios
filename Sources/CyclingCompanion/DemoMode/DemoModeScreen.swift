import Foundation
import RoutePersistence
import SwiftUI

/// Backs `DemoModeScreen`'s observable state (RULE-16 in spec/rules.md): the selected replay
/// speed, always clamped through `DemoMode.clampSpeed` (AC-47 through AC-51, Milestone 3) so
/// nothing downstream ever sees an out-of-range value.
#if DEBUG
@MainActor
@Observable
final class DemoModeViewModel {
    private(set) var speed: Double = 1
    private(set) var activeSession: RideSession?

    func setSpeed(_ requested: Double) {
        speed = DemoMode.clampSpeed(requested)
    }

    func setActiveSession(_ session: RideSession?) {
        activeSession = session
    }

    /// AC-24: forces the next advisor check on the active demo session immediately, without
    /// waiting out the (speed-scaled) cadence — the same `RideSession.forceNextCheck()`
    /// mechanism task-1.3 already validated, exercised here through the screen's own action.
    /// A no-op if no demo ride is currently running.
    func forceNextCheck() async {
        await activeSession?.forceNextCheck()
    }
}

/// Constructs a Demo Mode `RideSession` — `DemoModeReplayDriver` substituted for both
/// `LocationSource` and `SensorSource`, a `SpeedScaledClock` for `RideTracker`/`FeatureEngine`
/// (RULE-1/RULE-7/RULE-15 in spec/rules.md, AC-21/AC-22/AC-23/AC-25) — against the *current*
/// route (dec-2 in tasks.yaml: Demo Mode reuses the same current-route pointer a live ride
/// would, rather than a self-contained bundled fixture route). Only ever constructed from
/// `DemoModeScreen`'s own `#if DEBUG` body (RULE-15): `DemoModeReplayDriver` doesn't exist in
/// Release, so this type must never move into a file compiled in every configuration.
/// `locationFixes`/`sensorSamples` are the fixture to replay — sourcing them from a bundled
/// app resource (vs. this milestone's injected-fixture scope) is deferred to the same
/// follow-up as the app's real navigation wiring (see spec/status.md).
@MainActor
struct DemoRideStarter {
    let routeStore: RouteStore
    let pointer: CurrentRoutePointer
    let appRouter: AppRouter
    let decisionLog: DecisionLog
    let notifier: Notifier
    let locationFixes: [LocationFix]
    let sensorSamples: [SensorSample]
    var advisorClient: AdvisorClient? = nil

    /// Returns the started `RideSession` (`nil` if there's no current route to ride against)
    /// so the caller — `DemoModeScreen`'s own "Start Demo Ride" action — can retain it for the
    /// force-check control (task-4.4) to reach later.
    @discardableResult
    func startDemoRide(speed: Double) async -> RideSession? {
        guard let routeId = pointer.routeId, let route = try? await routeStore.fetch(routeId: routeId) else {
            return nil
        }
        guard let rideStoreURL = try? RideStore.defaultFileURL() else {
            return nil
        }
        let clampedSpeed = DemoMode.clampSpeed(speed)
        let rideStore = RideStore(fileURL: rideStoreURL)
        let driver = DemoModeReplayDriver(
            locationFixes: locationFixes, sensorSamples: sensorSamples, clock: SystemClock(), speed: clampedSpeed)
        let demoClock = SpeedScaledClock(base: SystemClock(), speed: clampedSpeed)

        let (tracker, session) = await makeTrackerAndSession(
            rideId: UUID().uuidString, routeId: routeId, startTime: Date(), route: route, locationSource: driver,
            sensorSource: driver, clock: demoClock, rideStore: rideStore, routeStore: routeStore,
            decisionLog: decisionLog, notifier: notifier, advisorClient: advisorClient)

        appRouter.show(.liveRide(startLiveRideTasks(tracker: tracker, session: session)))
        return session
    }
}

/// The Demo Mode screen (RULE-14 in spec/rules.md, AC-20/AC-25) — speed selection, starting a
/// demo ride, and the debug-only force-check control (AC-24). `#if DEBUG`-gated along with
/// everything else Demo Mode touches, so it compiles out of Release entirely. `onStart` is
/// `DemoRideStarter.startDemoRide` (or an equivalent); its returned `RideSession` is retained
/// by `viewModel` so Force Check has something to call `forceNextCheck()` on.
struct DemoModeScreen: View {
    @State private var viewModel = DemoModeViewModel()
    let onStart: (Double) async -> RideSession?

    var body: some View {
        VStack(spacing: 16) {
            Slider(value: Binding(get: { viewModel.speed }, set: { viewModel.setSpeed($0) }), in: 1...20, step: 1)
            Text("\(Int(viewModel.speed))x")
            Button("Start Demo Ride") {
                Task {
                    let session = await onStart(viewModel.speed)
                    viewModel.setActiveSession(session)
                }
            }
            Button("Force Check") {
                Task { await viewModel.forceNextCheck() }
            }
        }
        .padding()
    }
}
#endif

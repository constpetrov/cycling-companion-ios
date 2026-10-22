import SwiftUI

/// The live ride screen (RULE-9/RULE-16 in spec/rules.md, AC-10/AC-11/AC-16) — reuses
/// `RideProgressView` to render an already-constructed, already-running `RideTracker`, plus a
/// Finish Ride button. `nil` only in the brief window before `RideResumer` has reconstructed a
/// tracker for an unfinished ride.
struct LiveRideScreen: View {
    let rideTracker: RideTracker?
    let onFinishRide: () -> Void

    var body: some View {
        if let rideTracker {
            VStack {
                RideProgressView(rideTracker: rideTracker)
                Button("Finish Ride", action: onFinishRide)
            }
        } else {
            ProgressView()
        }
    }
}

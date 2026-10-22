import SwiftUI

/// The live ride screen (RULE-9/RULE-16 in spec/rules.md, AC-10/AC-11/AC-16) — reuses
/// `RideProgressView` to render an already-running `RideTracker`, plus a Finish Ride button.
/// Shown inside the ride cover only while a ride is active, so there is always a tracker.
struct LiveRideScreen: View {
    let rideTracker: RideTracker
    let onFinishRide: () -> Void

    var body: some View {
        VStack {
            RideProgressView(rideTracker: rideTracker)
            Button("Finish Ride", action: onFinishRide)
        }
    }
}

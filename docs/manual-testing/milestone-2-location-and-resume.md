# Manual Testing: CoreLocation tracking & background resume (Milestone 2, task-4.2/4.3)

## Why this is manual

`task-4.2` (real `CoreLocationSource`) and `task-4.3` (background relaunch + resume wiring)
are both marked "Manual" in `spec/tasks.yaml` — they depend on real CoreLocation/iOS
background behavior that XCTest cannot drive. The resume *logic* itself is already proven
automatically (`RideTrackerResumeTests`); what's left is proving the real plumbing reaches it.

## Prerequisite: there's no UI wired to this yet

`spec.md` explicitly defers real navigation wiring this milestone — `ContentView` is still a
placeholder, and nothing in the shipped app currently starts a `RideTracker`. To observe
anything, temporarily add a debug harness (remove it before committing anything else):

```swift
// Sources/CyclingCompanion/App/ContentView.swift — TEMPORARY, revert after testing
import SwiftUI
import RoutePersistence

struct ContentView: View {
    @State private var tracker: RideTracker?

    var body: some View {
        Group {
            if let tracker {
                RideProgressView(rideTracker: tracker)
            } else {
                Text("Starting…")
            }
        }
        .task {
            guard let fileURL = try? RideStore.defaultFileURL() else { return }
            let rideStore = RideStore(fileURL: fileURL)
            let route = [
                ResampledPoint(latitude: 52.0, longitude: 13.0, elevationMeters: nil, cumulativeDistanceMeters: 0),
                ResampledPoint(latitude: 52.0, longitude: 13.1, elevationMeters: nil, cumulativeDistanceMeters: 10_000),
            ]
            let tracker = RideTracker(
                rideId: "debug-ride", routeId: "debug-route", startTime: Date(), route: route,
                locationSource: CoreLocationSource(), sensorSource: NoSensorSource(), clock: SystemClock(),
                rideStore: rideStore)
            try? await tracker.resumeIfNeeded(from: rideStore)
            self.tracker = tracker
            await tracker.start()
        }
    }
}
```

Swap the route's coordinates for wherever you'll actually be walking/driving/simulating, so
distance actually advances instead of sitting off-route the whole time.

## 1. Testing on a real device

1. Connect the device, select it as the run destination in Xcode, and Run (⌘R).
2. On first launch you should see the "When In Use" location prompt (text matches
   `NSLocationWhenInUseUsageDescription`). Allow it.
3. iOS should then prompt to upgrade to "Always" (matches
   `NSLocationAlwaysAndWhenInUseUsageDescription`) — if it doesn't prompt automatically, open
   Settings → Privacy & Security → Location Services → Cycling Companion and set it to
   "Always" manually. Confirm it reads "Always" before continuing.
4. With the debug screen open, walk or drive a short distance. Distance done/remaining/speed
   on screen should update and roughly track real movement — this is `CoreLocationSource`
   actually feeding `RideTracker`.
5. Background resume check:
   a. Lock the screen (or background the app) while still moving.
   b. Keep moving for a bit, then force-quit the app from the App Switcher.
   c. Keep moving for a few more minutes — a background relaunch is triggered by iOS on a
      *significant location change*, which needs real elapsed movement after the kill; it's
      not instant.
   d. Watch for the app silently relaunching (check the App Switcher, or attach the debugger
      and set a breakpoint in `AppDelegate.application(_:didFinishLaunchingWithOptions:)` to
      confirm `launchOptions?[.location]` was actually present).
   e. Once relaunched, confirm `resumeIfNeeded` restored distance/moving-time close to what it
      was right before the kill (add a temporary `print` in `AppDelegate` if you want this
      visible in the console instead of stepping through the debugger).
6. Revert `ContentView.swift` back to the placeholder when done.

## 2. Testing in the Simulator

The Simulator has no real GPS — use Xcode's simulated-location feature instead.

1. Run the app on a Simulator device (⌘R).
2. With the app running, open Xcode's **Debug → Simulate Location** menu and pick a built-in
   route (e.g. "City Run") or a custom coordinate sequence. This feeds a continuous stream of
   simulated fixes through `CoreLocationSource` exactly as real hardware would.
   - Command-line alternative: `xcrun simctl location <device-id> start <lat>,<lon>` for a
     fixed point, or check `xcrun simctl location --help` for your Xcode version's GPX/route
     playback support — useful if you want movement to keep running after Xcode's debug
     session stops (see step 5).
3. Grant "When In Use" then "Always" when the Simulator shows the same system prompts as a
   real device.
4. Confirm the debug screen's distance/speed update as the simulated route plays.
5. Background resume check (less reliable than a real device — treat the device pass as
   authoritative if these disagree):
   a. Start simulated location via `simctl location ... start/run` from Terminal (not tied to
      Xcode's Run session), so it keeps "moving" independent of the app's process.
   b. Stop the app from Xcode (the stop button) to simulate a force-quit.
   c. Relaunch the app from the Simulator's home screen (not Xcode's Run button), while the
      simulated location keeps changing.
   d. Same confirmation as the device test: breakpoint/print in `AppDelegate` to confirm the
      location launch option was seen, and that `resumeIfNeeded` restored the prior state.
6. Revert `ContentView.swift` back to the placeholder when done.

## Notes

- Apple's own Simulator background-launch behavior is documented as less reliable than real
  hardware — if the Simulator pass doesn't reproduce a relaunch, that doesn't necessarily mean
  the real device will fail too.
- These checks validate the real CoreLocation/iOS plumbing only. The resume *logic* (state
  rehydration, no-op when nothing's unfinished, ETA recompute) is already covered by
  `RideTrackerResumeTests` and doesn't need re-proving here.

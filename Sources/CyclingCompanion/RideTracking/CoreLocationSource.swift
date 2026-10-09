@preconcurrency import CoreLocation

/// Production `LocationSource` (RULE-6/RULE-7 in spec/rules.md): `CLLocationManager`
/// configured for the `.fitness` activity type — not `.automotiveNavigation`,
/// `.otherNavigation`, or continuous best-accuracy — and requesting "Always" authorization,
/// since reliable background recording while the phone is pocketed mid-ride needs it (AC-20).
/// `@unchecked Sendable`: `CLLocationManagerDelegate` is an Objective-C delegate protocol
/// bridging an inherently non-Sendable framework boundary; delivery happens on the run loop
/// `startUpdatingLocation()` was called from, same as every other `CLLocationManagerDelegate`
/// adapter.
final class CoreLocationSource: NSObject, LocationSource, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager: CLLocationManager
    private var continuation: AsyncStream<LocationFix>.Continuation?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.requestAlwaysAuthorization()
    }

    func locationUpdates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            self.continuation = continuation
            manager.startUpdatingLocation()
            continuation.onTermination = { [weak self] _ in
                self?.manager.stopUpdatingLocation()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            continuation?.yield(
                LocationFix(
                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                    // CLLocation.speed is -1 when invalid; floor at 0 rather than feed a negative speed downstream.
                    speedMetersPerSecond: max(location.speed, 0), timestamp: location.timestamp))
        }
    }
}

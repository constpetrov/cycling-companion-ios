import Foundation
import RoutePersistence

#if DEBUG
enum DemoFixture {
    /// Simulates 18 km/h along the current route. Split long segments into at most
    /// five seconds of ride time, retaining every vertex so bends are never skipped.
    /// Timestamps share the ride's time origin; replay acceleration is applied by the driver.
    static func locationFixes(for route: PersistedRoute, startTime: Date) -> [LocationFix] {
        let points = route.points
        guard points.count >= 2, let first = points.first, let last = points.last,
            last.cumulativeDistanceMeters > first.cumulativeDistanceMeters
        else { return [] }

        let speed = 5.0
        var fixes = [LocationFix(
            latitude: first.latitude, longitude: first.longitude, speedMetersPerSecond: speed,
            timestamp: startTime)]

        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let distance = b.cumulativeDistanceMeters - a.cumulativeDistanceMeters
            guard distance > 0 else { continue }
            let steps = Int(ceil(distance / (speed * 5)))
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                let elapsed = (a.cumulativeDistanceMeters - first.cumulativeDistanceMeters + distance * fraction) / speed
                fixes.append(LocationFix(
                    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                    longitude: a.longitude + (b.longitude - a.longitude) * fraction,
                    speedMetersPerSecond: speed,
                    timestamp: startTime.addingTimeInterval(elapsed)))
            }
        }
        if let finish = fixes.popLast() {
            fixes.append(LocationFix(
                latitude: finish.latitude, longitude: finish.longitude, speedMetersPerSecond: 0,
                timestamp: finish.timestamp))
        }
        return fixes
    }
}
#endif

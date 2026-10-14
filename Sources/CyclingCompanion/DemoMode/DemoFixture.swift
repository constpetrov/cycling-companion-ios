import Foundation

/// A bundled Demo Mode fixture (RULE-26/RULE-27 in spec/rules.md, AC-20/AC-21/AC-22) — the
/// same combined, timestamp-ordered, kind-discriminated JSON shape the test target's
/// `RideFixtureEntry` already uses (see `Tests/CyclingCompanionTests/Fixtures/`), promoted
/// into the main target so Demo Mode has something real to replay without depending on the
/// test target. `#if DEBUG`-gated along with everything else Demo Mode touches.
#if DEBUG
private struct DemoFixtureEntry: Decodable {
    let kind: String
    let timestamp: TimeInterval
    let latitude: Double?
    let longitude: Double?
    let speedMetersPerSecond: Double?
    let heartRateBPM: Int?
    let cadenceRPM: Int?

    var asLocationFix: LocationFix? {
        guard kind == "location", let latitude, let longitude, let speedMetersPerSecond else { return nil }
        return LocationFix(
            latitude: latitude, longitude: longitude, speedMetersPerSecond: speedMetersPerSecond,
            timestamp: Date(timeIntervalSince1970: timestamp))
    }

    var asSensorSample: SensorSample? {
        guard kind == "sensor" else { return nil }
        return SensorSample(heartRateBPM: heartRateBPM, cadenceRPM: cadenceRPM, timestamp: Date(timeIntervalSince1970: timestamp))
    }
}

enum DemoFixture {
    /// Loads `demo_ride.json` from the app bundle, splitting it into the `LocationFix`/
    /// `SensorSample` arrays `DemoRideStarter` feeds to `DemoModeReplayDriver`. Empty arrays
    /// (not a crash) if the resource is somehow missing.
    static func loadBundled() -> (locationFixes: [LocationFix], sensorSamples: [SensorSample]) {
        guard let url = Bundle.main.url(forResource: "demo_ride", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([DemoFixtureEntry].self, from: data)
        else {
            return ([], [])
        }
        return (entries.compactMap(\.asLocationFix), entries.compactMap(\.asSensorSample))
    }
}
#endif

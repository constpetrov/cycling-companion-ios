import Foundation

@testable import CyclingCompanion

/// One entry in a combined, timestamp-ordered ride fixture (RULE-16 in spec/rules.md):
/// `kind` discriminates `"location"` from `"sensor"`, with only that kind's fields populated.
/// Loaded from the JSON files under `Tests/CyclingCompanionTests/Fixtures/`.
struct RideFixtureEntry: Codable {
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

enum RideFixtureLoader {
    static func load(resource: String, bundle: Bundle) throws -> [RideFixtureEntry] {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RideFixtureEntry].self, from: data)
    }
}

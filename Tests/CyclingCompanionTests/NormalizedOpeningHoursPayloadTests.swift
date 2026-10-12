import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-1.3 validation (RULE-32 in spec/rules.md): the iOS mirror structures decode the
/// backend's actual field names correctly, and `PersistedPoiInput`'s copy stays decodable
/// against JSON cached before this field existed.
final class NormalizedOpeningHoursPayloadTests: XCTestCase {

    func testCorridorPoiResponseDecodesTheBackendsActualFieldNames() throws {
        let json = """
            {
              "osmId": 42,
              "type": "CAFE_BAKERY_RESTAURANT",
              "name": "Café Sample",
              "latitude": 52.0,
              "longitude": 13.0,
              "kmMarkMeters": 1000.0,
              "detourMeters": 50.0,
              "openingHours": "Mo-Fr 08:00-18:00",
              "normalizedOpeningHours": {
                "alwaysOpen": false,
                "unknown": false,
                "intervals": [
                  {"dayOfWeek": 1, "startMinuteOfDay": 480, "endMinuteOfDay": 1080}
                ]
              }
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CorridorPoiResponse.self, from: json)

        XCTAssertEqual(decoded.osmId, 42)
        XCTAssertFalse(decoded.normalizedOpeningHours.alwaysOpen)
        XCTAssertFalse(decoded.normalizedOpeningHours.unknown)
        XCTAssertEqual(decoded.normalizedOpeningHours.intervals.count, 1)
        XCTAssertEqual(decoded.normalizedOpeningHours.intervals[0].dayOfWeek, 1)
        XCTAssertEqual(decoded.normalizedOpeningHours.intervals[0].startMinuteOfDay, 480)
        XCTAssertEqual(decoded.normalizedOpeningHours.intervals[0].endMinuteOfDay, 1080)
    }

    func testPersistedPoiInputDecodesOldCacheMissingTheNewKeyWithNilField() throws {
        // Matches exactly what RouteStore wrote to disk before this field existed — no
        // "normalizedOpeningHours" key at all, not even null.
        let oldCacheJSON = """
            {
              "osmId": 42,
              "type": "CAFE_BAKERY_RESTAURANT",
              "name": "Café Sample",
              "latitude": 52.0,
              "longitude": 13.0,
              "kmMarkMeters": 1000.0,
              "detourMeters": 50.0,
              "openingHours": "Mo-Fr 08:00-18:00"
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PersistedPoiInput.self, from: oldCacheJSON)

        XCTAssertEqual(decoded.osmId, 42)
        XCTAssertNil(decoded.normalizedOpeningHours)
    }

    func testPersistedPoiInputRoundTripsThroughEncodeAndDecodeWithTheNewFieldPopulated() throws {
        let original = PersistedPoiInput(
            osmId: 42, type: "CAFE_BAKERY_RESTAURANT", name: "Café Sample", latitude: 52.0, longitude: 13.0,
            kmMarkMeters: 1000.0, detourMeters: 50.0, openingHours: "Mo-Fr 08:00-18:00",
            normalizedOpeningHours: PersistedNormalizedOpeningHours(
                alwaysOpen: false, unknown: false,
                intervals: [PersistedWeeklyOpenInterval(dayOfWeek: 1, startMinuteOfDay: 480, endMinuteOfDay: 1080)]))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PersistedPoiInput.self, from: data)

        XCTAssertEqual(decoded.normalizedOpeningHours?.intervals.count, 1)
        XCTAssertEqual(decoded.normalizedOpeningHours?.intervals.first?.endMinuteOfDay, 1080)
    }
}

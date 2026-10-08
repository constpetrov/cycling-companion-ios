import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// AC-30, AC-31 in spec/criteria.md.
///
/// Tests only the `points:`/`pois:` initializer, which maps plain `Codable` structs to map
/// coordinates/pins with no `ModelContext` involved. This deliberately avoids exercising the
/// SwiftData insert->save->fetch cycle, which is the part of the stack blocked by the known
/// issue in docs/known-issues/swiftdata-xcode27-model-crash.md (task-2.6).
final class CorridorMapViewTests: XCTestCase {

    func testMapsRoutePointsToPolylineCoordinates() {
        let points = [
            PersistedPointInput(latitude: 52.0, longitude: 13.0, elevationMeters: 34.0, cumulativeDistanceMeters: 0),
            PersistedPointInput(latitude: 52.001, longitude: 13.001, elevationMeters: 36.0, cumulativeDistanceMeters: 50),
        ]

        let view = CorridorMapView(points: points, pois: [])

        XCTAssertEqual(view.routeCoordinates.count, 2)
        XCTAssertEqual(view.routeCoordinates[0].latitude, 52.0, accuracy: 1e-9)
        XCTAssertEqual(view.routeCoordinates[0].longitude, 13.0, accuracy: 1e-9)
        XCTAssertEqual(view.routeCoordinates[1].latitude, 52.001, accuracy: 1e-9)
        XCTAssertEqual(view.routeCoordinates[1].longitude, 13.001, accuracy: 1e-9)
    }

    func testMapsCorridorPoisToPins() {
        let pois = [
            PersistedPoiInput(
                osmId: 42, type: "drinking_water", name: "Fountain", latitude: 52.0005, longitude: 13.0005,
                kmMarkMeters: 25, detourMeters: 10, openingHours: "24/7"),
            PersistedPoiInput(
                osmId: 43, type: "bike_shop", name: nil, latitude: 52.0009, longitude: 13.0009,
                kmMarkMeters: 48, detourMeters: 5, openingHours: nil),
        ]

        let view = CorridorMapView(points: [], pois: pois)

        XCTAssertEqual(view.pins.count, 2)
        XCTAssertEqual(view.pins[0].id, 42)
        XCTAssertEqual(view.pins[0].name, "Fountain")
        XCTAssertEqual(view.pins[0].type, "drinking_water")
        XCTAssertEqual(view.pins[1].id, 43)
        XCTAssertNil(view.pins[1].name)
        XCTAssertEqual(view.pins[1].type, "bike_shop")
    }
}

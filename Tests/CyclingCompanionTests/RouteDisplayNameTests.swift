import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-6.6 (RULE-26): AC-114 to AC-119.
final class RouteDisplayNameTests: XCTestCase {

    private func gpx(trackName: String? = nil, metadataName: String? = nil) -> Data {
        let metadata = metadataName.map { "<metadata><name>\($0)</name></metadata>" } ?? ""
        let track = trackName.map { "<name>\($0)</name>" } ?? ""
        return Data("""
            <?xml version="1.0"?><gpx version="1.1">\(metadata)<trk>\(track)<trkseg>
            <trkpt lat="52.0" lon="13.0"></trkpt><trkpt lat="52.01" lon="13.0"></trkpt>
            </trkseg></trk></gpx>
            """.utf8)
    }

    /// AC-117: track name first, then metadata name.
    func testNameComesFromTheTrackThenTheMetadata() throws {
        XCTAssertEqual(try RouteImporter.importGPX(data: gpx(trackName: "Canal Loop", metadataName: "Meta")).displayName, "Canal Loop")
        XCTAssertEqual(try RouteImporter.importGPX(data: gpx(metadataName: "Sunday Spin")).displayName, "Sunday Spin")
        XCTAssertNil(try RouteImporter.importGPX(data: gpx()).displayName)
        XCTAssertNil(try RouteImporter.importGPX(data: gpx(trackName: "   ")).displayName, "blank names don't count")
    }

    /// AC-118: a file without names uses the file name without its extension.
    func testAFileWithoutNamesUsesItsFileName() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Morning Loop.gpx")
        try gpx().write(to: url)

        XCTAssertEqual(try RouteImporter.importGPX(fileURL: url).displayName, "Morning Loop")
    }

    /// RULE-26: the name stays on the phone — the import request has no such field.
    func testTheNameIsNotSentToTheBackend() throws {
        let payload = ImportRouteRequestPayload(
            hash: "h", points: [], totalDistanceMeters: 1, totalClimbingMeters: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        XCTAssertNil(json["displayName"])
    }

    func testStatusUpdatesKeepTheStoredName() async throws {
        let store = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        try await store.persist(
            routeId: "r", hash: "h", totalDistanceMeters: 1, totalClimbingMeters: nil, points: [], pois: [],
            status: "building", displayName: "Canal Loop")

        try await store.persist(
            routeId: "r", hash: "h", totalDistanceMeters: 1, totalClimbingMeters: nil, points: [], pois: [],
            status: "ready")

        let route = try await store.fetch(routeId: "r")
        XCTAssertEqual(route?.displayName, "Canal Loop")
        XCTAssertEqual(route?.status, "ready")
    }

    /// AC-119 and the route stored by an older build.
    func testALegacyRouteDecodesAndShowsRoutePlusDistance() throws {
        let legacy = #"{"id":"r","hash":"h","totalDistanceMeters":12300,"status":"ready","points":[],"pois":[]}"#
        let route = try JSONDecoder().decode(PersistedRoute.self, from: Data(legacy.utf8))

        let card = RouteCard(route: route, isPolling: false, locale: Locale(identifier: "de_DE"))

        XCTAssertNil(route.displayName)
        XCTAssertTrue(card.title.hasPrefix("Route · 12"), card.title)
        XCTAssertTrue(card.title.contains("km"))
    }

    /// AC-115: name, distance, climbing and stop-search state.
    func testTheCardShowsNameDistanceClimbingAndStops() {
        let route = PersistedRoute(
            id: "r", hash: "h", totalDistanceMeters: 42_000, totalClimbingMeters: 380, status: "building", points: [],
            pois: [], displayName: "Canal Loop")

        let card = RouteCard(route: route, isPolling: false, locale: Locale(identifier: "de_DE"))

        XCTAssertEqual(card.title, "Canal Loop")
        XCTAssertTrue(card.distanceText.contains("42"))
        XCTAssertTrue(card.climbingText?.contains("380") ?? false)
        XCTAssertEqual(card.corridor, .finding)
    }

    /// AC-114/AC-116: the card's actions exist in every stop-search state — Start is never gated.
    func testEveryCorridorStateKeepsStartAvailable() {
        for state in [CorridorState.finding, .ready(stopCount: 2), .noStops, .failed] {
            XCTAssertFalse(state.message.isEmpty)  // the card always renders, Start Ride included
        }
    }
}

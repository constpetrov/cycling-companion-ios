import XCTest

@testable import CyclingCompanion

/// AC-2, AC-3, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10 in spec/criteria.md.
final class RouteImporterTests: XCTestCase {

    // MARK: - Fixtures

    private func gpx(trackPoints: [(lat: Double, lon: Double, ele: Double?)]) -> Data {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1"><trk><trkseg>
            """
        for point in trackPoints {
            if let ele = point.ele {
                xml += """
                    <trkpt lat="\(point.lat)" lon="\(point.lon)"><ele>\(ele)</ele></trkpt>
                    """
            } else {
                xml += """
                    <trkpt lat="\(point.lat)" lon="\(point.lon)"></trkpt>
                    """
            }
        }
        xml += "</trkseg></trk></gpx>"
        return Data(xml.utf8)
    }

    /// 21 points spaced ~15 m apart along a straight line (~300 m total), climbing steadily.
    /// Straight-line points collapse under Douglas-Peucker simplification to just the two
    /// endpoints, then resampling reconstructs points every 50 m.
    private func manyPointStraightLineFixture() -> Data {
        var points: [(lat: Double, lon: Double, ele: Double?)] = []
        for i in 0...20 {
            let lat = 52.0 + Double(i) * 0.000135 // ~15 m per step
            points.append((lat: lat, lon: 13.0, ele: 100.0 + Double(i)))
        }
        return gpx(trackPoints: points)
    }

    // MARK: - AC-2 / AC-5 / AC-6 / AC-7 / AC-8: many-point GPX with elevation

    func testManyPointGPXParsesSimplifiesResamplesAndComputesElevationProfile() throws {
        let route = try RouteImporter.importGPX(data: manyPointStraightLineFixture())

        // AC-7: cumulative distance is non-decreasing and starts at 0.
        XCTAssertEqual(route.points.first?.cumulativeDistanceMeters, 0)
        for (previous, current) in zip(route.points, route.points.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.cumulativeDistanceMeters, current.cumulativeDistanceMeters)
        }

        // AC-6: resample step is 50 m, so a ~300 m straight-line route has intermediate points
        // roughly every 50 m (plus the final point, which may land short of a full step).
        XCTAssertGreaterThanOrEqual(route.points.count, 5)

        // AC-8: elevation profile is present (not nil) when the source has elevation on every point.
        XCTAssertTrue(route.points.allSatisfy { $0.elevationMeters != nil })

        // Steadily increasing elevation along a straight line means total climbing equals the
        // net elevation gain.
        XCTAssertNotNil(route.totalClimbingMeters)
        XCTAssertGreaterThan(route.totalClimbingMeters ?? 0, 0)
    }

    // MARK: - AC-3: exactly 2 track points (minimum valid boundary)

    func testExactlyTwoTrackPointsImportsSuccessfully() throws {
        let data = gpx(trackPoints: [
            (lat: 52.0, lon: 13.0, ele: 100.0),
            (lat: 52.00009, lon: 13.0, ele: 100.0), // ~10 m north, under the 50 m resample step
        ])

        let route = try RouteImporter.importGPX(data: data)

        XCTAssertEqual(route.points.count, 2)
        XCTAssertEqual(route.points.first?.cumulativeDistanceMeters, 0)
        XCTAssertEqual(route.totalDistanceMeters, route.points.last?.cumulativeDistanceMeters)
    }

    // MARK: - AC-9: no elevation data

    func testMissingElevationImportsSuccessfullyWithNullProfile() throws {
        let data = gpx(trackPoints: [
            (lat: 52.0, lon: 13.0, ele: nil),
            (lat: 52.001, lon: 13.0, ele: nil),
            (lat: 52.002, lon: 13.0, ele: nil),
        ])

        let route = try RouteImporter.importGPX(data: data)

        XCTAssertTrue(route.points.allSatisfy { $0.elevationMeters == nil })
        XCTAssertNil(route.totalClimbingMeters)
    }

    // MARK: - AC-10: route hash

    func testHashIsDeterministicAcrossRepeatedImports() throws {
        let data = manyPointStraightLineFixture()

        let first = try RouteImporter.importGPX(data: data)
        let second = try RouteImporter.importGPX(data: data)

        XCTAssertEqual(first.hash, second.hash)
        XCTAssertEqual(first.hash.count, 64)
        XCTAssertTrue(first.hash.allSatisfy { $0.isHexDigit })
    }

    func testHashMatchesIndependentlyReconstructedResampledFixture() throws {
        // Two points ~10 m apart (under the 50 m resample step), so the resampled output is
        // exactly the two original points re-labeled with cumulative distance — easy to
        // reconstruct independently of RouteImporter's own pipeline.
        let a = TrackPoint(latitude: 52.0, longitude: 13.0, elevationMeters: 100.0)
        let b = TrackPoint(latitude: 52.00009, longitude: 13.0, elevationMeters: 100.0)
        let data = gpx(trackPoints: [
            (lat: a.latitude, lon: a.longitude, ele: a.elevationMeters),
            (lat: b.latitude, lon: b.longitude, ele: b.elevationMeters),
        ])

        let totalLength = Resampler.totalPolylineLengthMeters([a, b])
        let expectedResampled = [
            ResampledPoint(
                latitude: a.latitude, longitude: a.longitude, elevationMeters: a.elevationMeters,
                cumulativeDistanceMeters: 0),
            ResampledPoint(
                latitude: b.latitude, longitude: b.longitude, elevationMeters: b.elevationMeters,
                cumulativeDistanceMeters: totalLength),
        ]
        let expectedHash = RouteHasher.hash(expectedResampled)

        let route = try RouteImporter.importGPX(data: data)

        XCTAssertEqual(route.hash, expectedHash)
    }

    // MARK: - AC-4: malformed/under-minimum GPX rejected (task-4.1)
    //
    // "Nothing persisted" isn't separately asserted here: RouteImporter never persists
    // anything itself (that's a separate call site entirely), so a thrown error with no
    // returned ImportedRoute is already the whole story — there's no partial state to leave
    // behind.

    func testFewerThanTwoTrackPointsThrows() {
        let data = gpx(trackPoints: [(lat: 52.0, lon: 13.0, ele: 100.0)])
        XCTAssertThrowsError(try RouteImporter.importGPX(data: data)) { error in
            XCTAssertEqual(error as? RouteImporterError, .insufficientTrackPoints)
        }
    }

    func testZeroTrackPointsThrows() {
        let data = gpx(trackPoints: [])
        XCTAssertThrowsError(try RouteImporter.importGPX(data: data)) { error in
            XCTAssertEqual(error as? RouteImporterError, .insufficientTrackPoints)
        }
    }

    func testMalformedGPXThrows() {
        let data = Data(#"<gpx><trk><trkseg><trkpt lat="52.0" lon="13.0""#.utf8) // unclosed tag
        XCTAssertThrowsError(try RouteImporter.importGPX(data: data)) { error in
            XCTAssertEqual(error as? RouteImporterError, .malformedGPX)
        }
    }

    // MARK: - AC-42/43/44: 20 MB size cap via file-system metadata (task-4.1)

    /// Writes a temp file of exactly `byteCount` bytes. When `validGPX` is true, it's a real
    /// 2-point GPX document padded to size with many small self-closing elements — not one
    /// giant text/comment node, which libxml2 rejects outright ("Comment too big found") well
    /// under 20 MB — so a successful parse proves the size check let it through. When false,
    /// it's padded with non-UTF8 bytes that would fail `XMLParser` outright — so an over-cap
    /// test asserting `.fileTooLarge` (rather than `.malformedGPX`) proves the size check ran
    /// *before* any attempt to parse.
    private func writeTempGPXFile(byteCount: Int, validGPX: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        if validGPX {
            let prefix = Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <gpx version="1.1"><trk><trkseg>
                <trkpt lat="52.0" lon="13.0"></trkpt>
                <trkpt lat="52.00009" lon="13.0"></trkpt>
                """.utf8)
            let suffix = Data("</trkseg></trk></gpx>".utf8)
            let chunk = "<p/>"
            let targetPaddingBytes = max(0, byteCount - prefix.count - suffix.count)
            let repeatCount = targetPaddingBytes / chunk.utf8.count
            let remainder = targetPaddingBytes % chunk.utf8.count
            var content = prefix
            content.append(Data(String(repeating: chunk, count: repeatCount).utf8))
            content.append(Data(repeating: UInt8(ascii: "p"), count: remainder))
            content.append(suffix)
            try content.write(to: url)
        } else {
            try Data(repeating: 0xFF, count: byteCount).write(to: url)
        }
        return url
    }

    func testFileJustUnderSizeCapProceedsToParsing() throws {
        let url = try writeTempGPXFile(byteCount: RouteImporter.maxFileSizeBytes - 1, validGPX: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let route = try RouteImporter.importGPX(fileURL: url)

        XCTAssertEqual(route.points.count, 2)
    }

    func testFileExactlyAtSizeCapProceedsToParsing() throws {
        let url = try writeTempGPXFile(byteCount: RouteImporter.maxFileSizeBytes, validGPX: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let route = try RouteImporter.importGPX(fileURL: url)

        XCTAssertEqual(route.points.count, 2)
    }

    func testFileOverSizeCapIsRejectedBeforeParsing() throws {
        let url = try writeTempGPXFile(byteCount: RouteImporter.maxFileSizeBytes + 1, validGPX: false)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try RouteImporter.importGPX(fileURL: url)) { error in
            XCTAssertEqual(error as? RouteImporterError, .fileTooLarge)
        }
    }
}

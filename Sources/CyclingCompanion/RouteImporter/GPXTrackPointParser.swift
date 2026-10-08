import Foundation

/// Streaming GPX parser (RULE-22 in spec/rules.md): extracts `<trkpt>` latitude/longitude/
/// elevation in document order using Foundation's `XMLParser`, with no third-party dependency.
final class GPXTrackPointParser: NSObject, XMLParserDelegate {
    private(set) var points: [TrackPoint] = []

    private var insideTrkpt = false
    private var insideEle = false
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentElevation: Double?
    private var elevationText = ""

    func parse(data: Data) throws -> [TrackPoint] {
        points = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw RouteImporterError.malformedGPX
        }
        return points
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "trkpt":
            insideTrkpt = true
            currentLatitude = attributeDict["lat"].flatMap(Double.init)
            currentLongitude = attributeDict["lon"].flatMap(Double.init)
            currentElevation = nil
        case "ele" where insideTrkpt:
            insideEle = true
            elevationText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideEle {
            elevationText += string
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "ele" where insideEle:
            currentElevation = Double(elevationText.trimmingCharacters(in: .whitespacesAndNewlines))
            insideEle = false
        case "trkpt":
            if let latitude = currentLatitude, let longitude = currentLongitude {
                points.append(
                    TrackPoint(latitude: latitude, longitude: longitude, elevationMeters: currentElevation))
            }
            insideTrkpt = false
        default:
            break
        }
    }
}

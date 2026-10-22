import Foundation

/// Streaming GPX parser (RULE-22 in spec/rules.md): extracts `<trkpt>` latitude/longitude/
/// elevation in document order using Foundation's `XMLParser`, with no third-party dependency.
final class GPXTrackPointParser: NSObject, XMLParserDelegate {
    private(set) var points: [TrackPoint] = []
    /// `<trk><name>` and `<metadata><name>`, trimmed; `nil` when absent or blank.
    private(set) var trackName: String?
    private(set) var metadataName: String?

    private var elementStack: [String] = []
    private var nameText = ""

    private var insideTrkpt = false
    private var insideEle = false
    private var currentLatitude: Double?
    private var currentLongitude: Double?
    private var currentElevation: Double?
    private var elevationText = ""

    func parse(data: Data) throws -> [TrackPoint] {
        points = []
        trackName = nil
        metadataName = nil
        elementStack = []
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
        elementStack.append(elementName)
        if elementName == "name" { nameText = "" }
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
        if elementStack.last == "name" {
            nameText += string
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { if !elementStack.isEmpty { elementStack.removeLast() } }
        if elementName == "name", elementStack.count >= 2 {
            let parent = elementStack[elementStack.count - 2]
            let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                if parent == "trk", trackName == nil { trackName = name }
                if parent == "metadata", metadataName == nil { metadataName = name }
            }
        }
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

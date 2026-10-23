import Foundation
import RoutePersistence

/// Which stops the maps draw (milestone 8 review): the stop data can put thousands of stops along a
/// city route, which MapKit renders as a solid wall of pins. The maps show only the nearest few of
/// each type ahead along the route, plus the stop currently suggested, so they stay readable and
/// cheap to redraw. The full list is still stored and used for suggestions.
enum MapStopSelection {
    static let perType = 2

    /// The `perType` nearest stops of each type at or beyond `progressMeters` along the route,
    /// plus `alwaysInclude` wherever it is, ordered by km mark.
    static func nearestAhead(
        _ stops: [PersistedPoiInput], from progressMeters: Double, perType: Int = perType, alwaysInclude: Int64? = nil
    ) -> [PersistedPoiInput] {
        let ahead = stops.filter { $0.kmMarkMeters >= progressMeters }
        var chosen = Dictionary(grouping: ahead, by: \.type).values.flatMap { sameType in
            sameType.sorted { $0.kmMarkMeters < $1.kmMarkMeters }.prefix(perType)
        }
        if let alwaysInclude, !chosen.contains(where: { $0.osmId == alwaysInclude }),
            let highlighted = stops.first(where: { $0.osmId == alwaysInclude })
        {
            chosen.append(highlighted)
        }
        return chosen.sorted { $0.kmMarkMeters < $1.kmMarkMeters }
    }
}

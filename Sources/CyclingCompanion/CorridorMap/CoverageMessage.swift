import Foundation
import RoutePersistence

/// What the app says about a route the backend's stop data only partly covers (milestone 8,
/// RULE-20; AC-42 to AC-46). Pure, so the rounding and the "entirely outside" threshold are
/// unit-tested without a view.
enum CoverageMessage {
    /// Within this of the whole route counts as "entirely outside": the backend measures the length
    /// outside on its copy of the points, which can differ from the phone's total by rounding.
    static let entirelyOutsideToleranceMeters: Double = 50

    /// Nothing when coverage is unknown or the route is fully covered; otherwise the message.
    static func text(outsideMeters: Double?, routeLengthMeters: Double, regionName: String?) -> String? {
        guard let outsideMeters, outsideMeters > 0 else { return nil }
        if outsideMeters >= routeLengthMeters - entirelyOutsideToleranceMeters {
            return "This route is outside the area we have stops for"
        }
        let kilometres = max(1, Int((outsideMeters / 1000).rounded()))
        return "Stops are only available in the \(regionName ?? "covered area") — \(kilometres) km of this route are outside"
    }

    static func text(for route: PersistedRouteCoverage) -> String? {
        text(outsideMeters: route.outsideMeters, routeLengthMeters: route.totalDistanceMeters, regionName: route.coverageRegion)
    }
}

/// The stored fields `CoverageMessage` reads.
protocol PersistedRouteCoverage {
    var outsideMeters: Double? { get }
    var totalDistanceMeters: Double { get }
    var coverageRegion: String? { get }
}

extension PersistedRoute: PersistedRouteCoverage {}

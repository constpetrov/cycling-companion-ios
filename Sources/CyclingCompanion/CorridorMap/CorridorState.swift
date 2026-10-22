import RoutePersistence

/// What the app says about a route's stops (RULE-24 in milestone 7's rules.md, AC-102 to AC-107),
/// derived from the stored status, the stored stops and whether a poll is running.
enum CorridorState: Equatable {
    case finding
    case ready(stopCount: Int)
    case noStops
    case failed

    static let buildingStatus = "building"
    static let readyStatus = "ready"
    static let failedStatus = "failed"

    init(route: PersistedRoute, isPolling: Bool) {
        if isPolling || route.status == Self.buildingStatus {
            self = .finding
        } else if route.status == Self.readyStatus {
            self = route.pois.isEmpty ? .noStops : .ready(stopCount: route.pois.count)
        } else {
            self = .failed
        }
    }

    var message: String {
        switch self {
        case .finding: "Finding stops…"
        case .ready(let count): count == 1 ? "1 stop found" : "\(count) stops found"
        case .noStops: "No stops found within 1.5 km"
        case .failed: "Couldn't find stops"
        }
    }

    /// AC-105/AC-107: Retry is offered only after a failure or timeout.
    var offersRetry: Bool { self == .failed }
}

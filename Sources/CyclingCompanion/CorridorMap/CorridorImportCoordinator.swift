import Foundation
import RoutePersistence

/// Drives a GPX import through to the corridor map screen (RULE-8/RULE-12 in spec/rules.md,
/// AC-6/AC-7/AC-8/AC-9): writes `RouteStore` *twice* for the same import, both times via
/// `RouteStore`'s existing `persist(...)` method. First, as soon as
/// `CorridorPollingService.importRoute` succeeds, persists the route's own points/hash/distance
/// with an empty `pois` list and the backend's own "building" status, writes the current-route
/// pointer, and navigates to the corridor map screen — before `pollUntilSettled` ever resolves.
/// Second, once `pollUntilSettled` succeeds in a background `Task`, persists the same `routeId`
/// again with the real `pois`/status and updates its own observed `pois` once. A failed import
/// leaves the pointer and `RouteStore` both untouched and surfaces an error instead. `points`
/// is set alongside `pois` at both moments — the app's wiring (not a formal milestone task)
/// needs it to actually render `CorridorMapScreen`'s polyline.
@MainActor
@Observable
final class CorridorImportCoordinator {
    private static let log = Log.logger(category: "CorridorImport")

    private(set) var points: [PersistedPointInput] = []
    private(set) var pois: [PersistedPoiInput] = []
    private(set) var importErrorMessage: String?
    /// Routes with a corridor poll running (RULE-24 in milestone 7's rules.md): at most one each.
    private(set) var pollingRouteIds: Set<String> = []
    private var polls: [String: Task<Void, Never>] = [:]

    private let corridorPollingService: CorridorPollingService
    private let routeStore: RouteStore
    private let pointer: CurrentRoutePointer
    private let appRouter: AppRouter
    private let lazySignIn: LazySignIn

    init(
        corridorPollingService: CorridorPollingService, routeStore: RouteStore, pointer: CurrentRoutePointer,
        appRouter: AppRouter, lazySignIn: LazySignIn
    ) {
        self.corridorPollingService = corridorPollingService
        self.routeStore = routeStore
        self.pointer = pointer
        self.appRouter = appRouter
        self.lazySignIn = lazySignIn
    }

    /// Returns the background poll `Task` so tests can explicitly await its completion when
    /// they need to assert on the settled state — production call sites ignore it entirely
    /// (`importRoute` itself has already returned by the time it would ever complete).
    @discardableResult
    func importRoute(_ route: ImportedRoute) async -> Task<Void, Never>? {
        do {
            return try await importRouteThrowing(route)
        } catch {
            importErrorMessage = "Couldn't import this route. Please try again."
            return nil
        }
    }

    /// The import itself, letting the caller tell failures apart (milestone 7, RULE-23). Returns the
    /// background poll `Task`, as `importRoute` does.
    @discardableResult
    func importRouteThrowing(_ route: ImportedRoute) async throws -> Task<Void, Never> {
        importErrorMessage = nil
        do {
            try await lazySignIn.ensureSignedIn()
            let response = try await corridorPollingService.importRoute(route)
            let persistedPoints = route.points.map(Self.persistedPoint)
            try await routeStore.persist(
                routeId: response.routeId, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
                totalClimbingMeters: route.totalClimbingMeters, points: persistedPoints, pois: [],
                status: response.status, displayName: route.displayName)
            points = persistedPoints
            pois = []
            pointer.routeId = response.routeId
            appRouter.open(.corridorMap(routeId: response.routeId))
            Self.log.info("Imported route \(response.routeId, privacy: .public), status=\(response.status, privacy: .public)")
            return pollAndUpdate(routeId: response.routeId)
        } catch {
            Self.log.error("Route import failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// AC-8/AC-9: polls in the background until the corridor settles, without blocking the import.
    /// RULE-24 (milestone 7): at most one poll per route — asking again while one runs returns it;
    /// the result is saved to that route only; a timeout or failure is saved as `failed`, so a
    /// relaunch shows "Couldn't find stops" instead of polling forever.
    @discardableResult
    private func pollAndUpdate(routeId: String) -> Task<Void, Never> {
        if let running = polls[routeId] {
            return running
        }
        pollingRouteIds.insert(routeId)
        let task = Task {
            defer {
                polls[routeId] = nil
                pollingRouteIds.remove(routeId)
            }
            do {
                // A poll started at launch or on opening the map may come before any sign-in this run.
                try await lazySignIn.ensureSignedIn()
                let status = try await corridorPollingService.pollUntilSettled(routeId: routeId)
                let newPois = (status.pois ?? []).map(Self.persistedPoi)
                await save(routeId: routeId, status: status.status, pois: newPois)
                // AC-112: a late result for a route that is no longer current only updates its own entry.
                if pointer.routeId == routeId {
                    pois = newPois
                }
            } catch {
                Self.log.notice(
                    "Corridor poll for route \(routeId, privacy: .public) ended without a result: \(String(describing: error), privacy: .public)")
                await save(routeId: routeId, status: CorridorState.failedStatus, pois: nil)
            }
        }
        polls[routeId] = task
        return task
    }

    func isPolling(routeId: String) -> Bool {
        pollingRouteIds.contains(routeId)
    }

    /// AC-108/AC-109: asks the backend to build the corridor again and polls; a no-op while a poll
    /// for that route is already running.
    @discardableResult
    func retry(routeId: String) async -> Task<Void, Never>? {
        guard polls[routeId] == nil else { return nil }
        do {
            try await lazySignIn.ensureSignedIn()
            let response = try await corridorPollingService.retry(routeId: routeId)
            await save(routeId: routeId, status: response.status, pois: nil)
        } catch {
            Self.log.notice("Corridor retry for route \(routeId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return pollAndUpdate(routeId: routeId)
    }

    /// AC-110: at launch, polls again for every stored route still building.
    func resumePollingForBuildingRoutes() async {
        let routes = (try? await routeStore.fetchAll()) ?? []
        for route in routes where route.status == CorridorState.buildingStatus {
            pollAndUpdate(routeId: route.id)
        }
    }

    /// AC-111: opening a route's corridor map polls again if it is building and nothing is polling.
    @discardableResult
    func ensurePolling(routeId: String) async -> Task<Void, Never>? {
        guard polls[routeId] == nil,
            let route = try? await routeStore.fetch(routeId: routeId),
            route.status == CorridorState.buildingStatus
        else { return nil }
        return pollAndUpdate(routeId: routeId)
    }

    /// A stored route as saved in `RouteStore` — what the corridor map shows, so it works after a
    /// relaunch (RULE-25 in milestone 7's rules.md).
    func storedRoute(id routeId: String) async -> PersistedRoute? {
        try? await routeStore.fetch(routeId: routeId)
    }

    /// Rewrites one stored route's status (and stops, when given), keeping everything else.
    private func save(routeId: String, status: String, pois newPois: [PersistedPoiInput]?) async {
        guard let route = try? await routeStore.fetch(routeId: routeId) else { return }
        try? await routeStore.persist(
            routeId: routeId, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
            totalClimbingMeters: route.totalClimbingMeters, points: route.points, pois: newPois ?? route.pois,
            status: status)
    }

    private static func persistedPoint(_ point: ResampledPoint) -> PersistedPointInput {
        PersistedPointInput(
            latitude: point.latitude, longitude: point.longitude, elevationMeters: point.elevationMeters,
            cumulativeDistanceMeters: point.cumulativeDistanceMeters)
    }

    private static func persistedPoi(_ poi: CorridorPoiResponse) -> PersistedPoiInput {
        PersistedPoiInput(
            osmId: poi.osmId, type: poi.type, name: poi.name, latitude: poi.latitude, longitude: poi.longitude,
            kmMarkMeters: poi.kmMarkMeters, detourMeters: poi.detourMeters, openingHours: poi.openingHours,
            normalizedOpeningHours: PersistedNormalizedOpeningHours(
                alwaysOpen: poi.normalizedOpeningHours.alwaysOpen, unknown: poi.normalizedOpeningHours.unknown,
                intervals: poi.normalizedOpeningHours.intervals.map {
                    PersistedWeeklyOpenInterval(
                        dayOfWeek: $0.dayOfWeek, startMinuteOfDay: $0.startMinuteOfDay,
                        endMinuteOfDay: $0.endMinuteOfDay)
                }))
    }
}

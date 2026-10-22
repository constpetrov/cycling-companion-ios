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
/// Why the last Retry failed, shown next to Retry (milestone 8, RULE-19).
enum CorridorActionError: Equatable, Sendable {
    case noConnection
    case server
}

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
    /// Routes whose Retry request is in flight (milestone 8, RULE-19): the id goes in before the
    /// first `await`, so a second tap can't send a second request.
    private(set) var retryInFlight: Set<String> = []
    /// The last Retry failure per route, shown next to Retry; cleared when Retry is tried again.
    private(set) var retryErrors: [String: CorridorActionError] = [:]

    private let corridorPollingService: CorridorPollingService
    private let routeStore: RouteStore
    private let pointer: CurrentRoutePointer
    private let appRouter: AppRouter
    private let lazySignIn: LazySignIn
    private let clock: Clock

    init(
        corridorPollingService: CorridorPollingService, routeStore: RouteStore, pointer: CurrentRoutePointer,
        appRouter: AppRouter, lazySignIn: LazySignIn, clock: Clock = SystemClock()
    ) {
        self.corridorPollingService = corridorPollingService
        self.routeStore = routeStore
        self.pointer = pointer
        self.appRouter = appRouter
        self.lazySignIn = lazySignIn
        self.clock = clock
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
    /// At most one poll per route — asking again while one runs returns it. Milestone 8 (RULE-18):
    /// re-checks with `PollBackoff` and no time limit, and only a backend `ready`/`failed` answer
    /// changes what is stored; a transient problem keeps the route `building` and a 404 just stops.
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
            var backoff = PollBackoff()
            while !Task.isCancelled {
                switch await checkStatus(routeId: routeId) {
                case .status(let payload) where payload.status != CorridorState.buildingStatus:
                    await apply(payload, to: routeId)
                    return
                case .notFound:
                    return  // the backend doesn't know this route; keep what is stored
                case .status, .transient:
                    break
                }
                do {
                    try await clock.sleep(for: backoff.next())
                } catch {
                    return  // cancelled: the app left the foreground
                }
            }
        }
        polls[routeId] = task
        return task
    }

    /// A status check that also covers signing in: a sign-in failure is just transient.
    private func checkStatus(routeId: String) async -> CorridorPollResult {
        do {
            try await lazySignIn.ensureSignedIn()
        } catch {
            return .transient
        }
        return await corridorPollingService.fetchStatus(routeId: routeId)
    }

    /// Saves a settled answer: `ready` replaces the stops and coverage, `failed` keeps the stops.
    private func apply(_ payload: CorridorStatusResponsePayload, to routeId: String) async {
        let newPois = payload.status == CorridorState.failedStatus ? nil : (payload.pois ?? []).map(Self.persistedPoi)
        await save(
            routeId: routeId, status: payload.status, pois: newPois, coverageRegion: payload.coverageRegion,
            outsideMeters: payload.outsideMeters)
        // AC-112: a late result for a route that is no longer current only updates its own entry.
        if let newPois, pointer.routeId == routeId {
            pois = newPois
        }
    }

    func isPolling(routeId: String) -> Bool {
        pollingRouteIds.contains(routeId)
    }

    /// The legacy Retry: asks the backend for the route's status again and polls if it's still
    /// building. Milestone 8 (RULE-19): one request at a time per route, with a remembered error.
    @discardableResult
    func retry(routeId: String) async -> Task<Void, Never>? {
        guard polls[routeId] == nil, !retryInFlight.contains(routeId) else { return nil }
        retryInFlight.insert(routeId)
        retryErrors[routeId] = nil
        defer { retryInFlight.remove(routeId) }
        do {
            try await lazySignIn.ensureSignedIn()
            let response = try await corridorPollingService.retry(routeId: routeId)
            await save(routeId: routeId, status: response.status, pois: nil)
        } catch {
            retryErrors[routeId] = error is URLError ? .noConnection : .server
            Self.log.notice("Corridor retry for route \(routeId, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return pollAndUpdate(routeId: routeId)
    }

    /// Milestone 8 (RULE-17): at launch and on every return to the foreground, asks once for the
    /// current route's corridor so its offline copy of the stops stays current. Only a `status`
    /// answer changes anything: `ready`/`failed` are saved, `building` starts the poll; offline,
    /// a server error, a sign-in failure or a 404 leave the stored route as it is.
    func refreshCurrentRoute() async {
        guard let routeId = pointer.routeId, polls[routeId] == nil else { return }
        guard case .status(let payload) = await checkStatus(routeId: routeId) else { return }
        if payload.status == CorridorState.buildingStatus {
            await save(routeId: routeId, status: payload.status, pois: nil)
            pollAndUpdate(routeId: routeId)
        } else {
            await apply(payload, to: routeId)
        }
    }

    /// Milestone 8 (RULE-18): no polling while the app isn't active; every route keeps its stored
    /// status and polling picks up again on return (`resumePollingForBuildingRoutes`).
    func pauseAllPolls() {
        for task in polls.values {
            task.cancel()
        }
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

    /// Rewrites one stored route's status (and stops and coverage, when given), keeping everything
    /// else.
    private func save(
        routeId: String, status: String, pois newPois: [PersistedPoiInput]?, coverageRegion: String? = nil,
        outsideMeters: Double? = nil
    ) async {
        guard let route = try? await routeStore.fetch(routeId: routeId) else { return }
        try? await routeStore.persist(
            routeId: routeId, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
            totalClimbingMeters: route.totalClimbingMeters, points: route.points, pois: newPois ?? route.pois,
            status: status, coverageRegion: coverageRegion, outsideMeters: outsideMeters)
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

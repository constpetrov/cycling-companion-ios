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
        importErrorMessage = nil
        do {
            try await lazySignIn.ensureSignedIn()
            let response = try await corridorPollingService.importRoute(route)
            let persistedPoints = route.points.map(Self.persistedPoint)
            try await routeStore.persist(
                routeId: response.routeId, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
                totalClimbingMeters: route.totalClimbingMeters, points: persistedPoints, pois: [],
                status: response.status)
            points = persistedPoints
            pois = []
            pointer.routeId = response.routeId
            appRouter.open(.corridorMap(routeId: response.routeId))
            Self.log.info("Imported route \(response.routeId, privacy: .public), status=\(response.status, privacy: .public)")
            return pollAndUpdate(routeId: response.routeId)
        } catch {
            importErrorMessage = "Couldn't import this route. Please try again."
            Self.log.error("Route import failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// AC-8/AC-9: fires a background `Task` and returns immediately, so `importRoute` itself
    /// doesn't wait on `pollUntilSettled` — the corridor map screen is already showing by the
    /// time this runs. `pollUntilSettled`'s own contract (Milestone 1) returns exactly once
    /// per full settle or throws, never progressively, so this is one terminal update.
    private func pollAndUpdate(routeId: String) -> Task<Void, Never> {
        Task {
            guard let status = try? await corridorPollingService.pollUntilSettled(routeId: routeId) else {
                return
            }
            guard let route = try? await routeStore.fetch(routeId: routeId) else {
                return
            }
            let newPois = (status.pois ?? []).map(Self.persistedPoi)
            try? await routeStore.persist(
                routeId: routeId, hash: route.hash, totalDistanceMeters: route.totalDistanceMeters,
                totalClimbingMeters: route.totalClimbingMeters, points: route.points, pois: newPois,
                status: status.status)
            pois = newPois
        }
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

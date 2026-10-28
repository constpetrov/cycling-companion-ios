import Foundation
import RoutePersistence

/// RULE-38 in milestone 10's rules.md: the one list of everything the app keeps for a rider —
/// imported routes, rides and ride checkpoints, queued uploads, the current-route pointer and the
/// stored refresh token. Navigation goes back to Home, so no pushed screen (a corridor map, Settings)
/// outlives the data it showed. Sign-out, account deletion and an account switch all erase through it, so
/// a store added later can't be forgotten in one of them.
@MainActor
struct LocalDataEraser {
    let routeStore: RouteStore
    let rideStore: RideStore
    let pendingUploadQueue: PendingRideUploadQueue
    let pointer: CurrentRoutePointer
    let corridorImportCoordinator: CorridorImportCoordinator
    let appRouter: AppRouter
    let session: AuthSession

    /// Everything, the session included (sign-out, account deletion).
    func eraseAll() async {
        await eraseLocalData()
        await session.clear()
    }

    /// The rider's data without the session: an account switch keeps the new session it just stored.
    func eraseLocalData() async {
        try? await routeStore.deleteAll()
        try? await rideStore.deleteAll()
        try? await pendingUploadQueue.removeAll()
        pointer.clear()
        corridorImportCoordinator.forgetEverything()
        appRouter.popToHome()
    }

    /// Whether there is anything to lose: a route, a ride or a queued upload.
    func hasData() async -> Bool {
        let routes = (try? await routeStore.fetchAll().count) ?? 0
        let rides = (try? await rideStore.fetchAll().count) ?? 0
        let queued = (try? await pendingUploadQueue.fetchAllOldestFirst().count) ?? 0
        return routes + rides + queued > 0
    }
}

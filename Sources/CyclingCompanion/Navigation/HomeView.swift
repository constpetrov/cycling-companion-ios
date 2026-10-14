import RoutePersistence
import SwiftUI

/// Backs `HomeView`'s observable state (RULE-16 in spec/rules.md): resolves the current route
/// from `CurrentRoutePointer` + `RouteStore`. A missing pointer, or a pointer `RouteStore` no
/// longer has an entry for (stale), both read as "show the import prompt" (AC-2) — never a
/// crash or a stuck loading state.
@MainActor
@Observable
final class HomeViewModel {
    private(set) var currentRoute: PersistedRoute?

    /// AC-2/AC-3: true whenever there's no current route to show.
    var showsImportPrompt: Bool {
        currentRoute == nil
    }

    private let routeStore: RouteStore
    private let pointer: CurrentRoutePointer

    init(routeStore: RouteStore, pointer: CurrentRoutePointer = CurrentRoutePointer()) {
        self.routeStore = routeStore
        self.pointer = pointer
    }

    /// Re-resolves `currentRoute` from the pointer + `RouteStore`.
    func refresh() async {
        guard let routeId = pointer.routeId else {
            currentRoute = nil
            return
        }
        do {
            currentRoute = try await routeStore.fetch(routeId: routeId)
        } catch {
            currentRoute = nil
        }
    }
}

/// The app's root screen (RULE-9 in spec/rules.md, AC-2/AC-3) — shows an "Import a route"
/// prompt or the current route with a Start Ride button. The import flow (task-2.4) and
/// Start Ride's `RideSession` construction (task-2.6) extend this same view.
struct HomeView: View {
    @State private var viewModel: HomeViewModel
    private let appRouter: AppRouter

    init(routeStore: RouteStore, appRouter: AppRouter) {
        _viewModel = State(initialValue: HomeViewModel(routeStore: routeStore))
        self.appRouter = appRouter
    }

    #if DEBUG
    /// AC-20/AC-25 (RULE-14 in spec/rules.md): always true in a Debug build — the entry point
    /// itself is unconditional; AC-25's Release exclusion comes entirely from this whole
    /// property (and the `NavigationLink` below) being compiled out via `#if DEBUG`, not from
    /// any runtime check.
    var showsDemoModeEntryPoint: Bool { true }
    #endif

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.showsImportPrompt {
                Text("Import a route")
            } else if let route = viewModel.currentRoute {
                Text("Route: \(route.id)")
                Button("Start Ride") {}
            }
            #if DEBUG
            NavigationLink("Demo Mode") {
                DemoModeScreen(onStart: { _ in nil })
            }
            #endif
        }
        .padding()
        .task { await viewModel.refresh() }
    }
}

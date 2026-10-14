import RoutePersistence
import SwiftUI
import UniformTypeIdentifiers

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
/// prompt or the current route with a Start Ride button. `coordinator` drives the actual
/// import flow (task-2.4); `onStartRide` is `RideStarter.startRide` (or an equivalent).
struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @State private var isImporterPresented = false
    private let coordinator: CorridorImportCoordinator
    private let onStartRide: () -> Void
    private let onStartDemoRide: (Double) async -> RideSession?

    private static let gpxContentType = UTType(filenameExtension: "gpx") ?? .xml

    /// `onStartDemoRide` is a plain closure, not a `DemoRideStarter` reference — `DemoRideStarter`
    /// only exists inside `#if DEBUG` (RULE-15), but this file is always compiled, so it can
    /// only ever hold the type-erased closure shape, never the concrete type itself. Defaults
    /// to a no-op so every existing call site keeps compiling unchanged.
    init(
        routeStore: RouteStore, coordinator: CorridorImportCoordinator, onStartRide: @escaping () -> Void,
        onStartDemoRide: @escaping (Double) async -> RideSession? = { _ in nil }
    ) {
        _viewModel = State(initialValue: HomeViewModel(routeStore: routeStore))
        self.coordinator = coordinator
        self.onStartRide = onStartRide
        self.onStartDemoRide = onStartDemoRide
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
                Button("Choose GPX File") { isImporterPresented = true }
            } else if let route = viewModel.currentRoute {
                Text("Route: \(route.id)")
                Button("Start Ride", action: onStartRide)
                Button("Choose GPX File") { isImporterPresented = true }
            }
            if let importErrorMessage = coordinator.importErrorMessage {
                Text(importErrorMessage)
            }
            #if DEBUG
            NavigationLink("Demo Mode") {
                DemoModeScreen(onStart: onStartDemoRide)
            }
            #endif
        }
        .padding()
        .task { await viewModel.refresh() }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [Self.gpxContentType]) { result in
            guard case .success(let fileURL) = result else {
                return
            }
            Task {
                let accessing = fileURL.startAccessingSecurityScopedResource()
                defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
                guard let imported = try? RouteImporter.importGPX(fileURL: fileURL) else {
                    return
                }
                await coordinator.importRoute(imported)
                await viewModel.refresh()
            }
        }
    }
}

import RoutePersistence
import SwiftUI
import UniformTypeIdentifiers

/// Why a route import failed (RULE-23 in milestone 7's rules.md, AC-97 to AC-101), each with its
/// own message.
enum ImportError: Equatable {
    case pickerFailed
    case unreadableGPX
    case noConnection
    case authFailed
    case backendRejected

    var message: String {
        switch self {
        case .pickerFailed: "The file couldn't be opened. Try choosing it again."
        case .unreadableGPX: "This file has no usable route. Choose a GPX file with a track."
        case .noConnection: "No connection. Check your internet and try again."
        case .authFailed: "Couldn't sign in to the server. Try again in a moment."
        case .backendRejected: "The server couldn't import this route. Try again later."
        }
    }

    init(networkError error: Error) {
        switch error {
        case is URLError:
            self = .noConnection
        case is AuthStubClientError:
            self = .authFailed
        case CorridorPollingError.rejected(let status) where status == 401 || status == 403:
            self = .authFailed
        default:
            self = .backendRejected
        }
    }
}

/// The import step `HomeViewModel` needs from `CorridorImportCoordinator`.
@MainActor
protocol RouteImporting: AnyObject {
    @discardableResult
    func importRouteThrowing(_ route: ImportedRoute) async throws -> Task<Void, Never>
    func isPolling(routeId: String) -> Bool
    @discardableResult
    func retry(routeId: String) async -> Task<Void, Never>?
}

/// What Home shows for the current route (RULE-26 in milestone 7's rules.md, AC-115 to AC-119).
struct RouteCard: Equatable {
    let routeId: String
    let title: String
    let distanceText: String
    let climbingText: String?
    let corridor: CorridorState

    init(route: PersistedRoute, isPolling: Bool, locale: Locale) {
        routeId = route.id
        distanceText = LiveRideViewModel.distanceText(meters: route.totalDistanceMeters, locale: locale)
        title = route.displayName ?? "Route · \(distanceText)"
        climbingText = route.totalClimbingMeters.map {
            Measurement(value: $0, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided).locale(locale))
        }
        corridor = CorridorState(route: route, isPolling: isPolling)
    }
}

extension CorridorImportCoordinator: RouteImporting {}

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
    private let importer: RouteImporting?
    private let locale: Locale
    private let rideStore: RideStore?

    /// AC-120: an unfinished ride that can't be resumed because its route is gone.
    private(set) var orphanedRideId: String?

    /// AC-95/AC-96: an import is in progress; both import entry points are disabled.
    private(set) var isImporting = false
    /// AC-97 to AC-101: why the last import failed, until dismissed or the next import starts.
    private(set) var importError: ImportError?

    init(
        routeStore: RouteStore, pointer: CurrentRoutePointer, importer: RouteImporting? = nil,
        locale: Locale = .current, rideStore: RideStore? = nil
    ) {
        self.routeStore = routeStore
        self.pointer = pointer
        self.importer = importer
        self.locale = locale
        self.rideStore = rideStore
    }

    func reportOrphanedRide(id: String) {
        orphanedRideId = id
    }

    /// AC-121: deletes the unfinished ride, so the notice doesn't come back on later launches.
    func discardOrphanedRide() async {
        guard let id = orphanedRideId else { return }
        try? await rideStore?.delete(rideId: id)
        orphanedRideId = nil
    }

    /// AC-115/AC-116.
    var routeCard: RouteCard? {
        currentRoute.map {
            RouteCard(route: $0, isPolling: importer?.isPolling(routeId: $0.id) ?? false, locale: locale)
        }
    }

    /// AC-105/AC-108 on Home.
    func retryCorridor() async {
        guard let routeId = currentRoute?.id, let importer else { return }
        let poll = await importer.retry(routeId: routeId)
        await refresh()
        await poll?.value
        await refresh()
    }

    /// The file picker failed (AC-97).
    func pickerFailed() {
        importError = .pickerFailed
    }

    func dismissImportError() {
        importError = nil
    }

    /// Reads, parses and uploads the chosen GPX file (RULE-23). Ignored while an import is running;
    /// on failure the current route is left as it was.
    func importGPX(from fileURL: URL) async {
        guard !isImporting, let importer else { return }
        isImporting = true
        importError = nil
        defer { isImporting = false }

        let imported: ImportedRoute
        do {
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            imported = try RouteImporter.importGPX(fileURL: fileURL)
        } catch {
            importError = .unreadableGPX
            return
        }
        do {
            try await importer.importRouteThrowing(imported)
        } catch {
            importError = ImportError(networkError: error)
            return
        }
        await refresh()
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
/// prompt or the current route with a Start Ride button. Reads its view model, the import
/// coordinator and the start actions from `AppDependencies`.
struct HomeView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var isImporterPresented = false

    private static let gpxContentType = UTType(filenameExtension: "gpx") ?? .xml

    #if DEBUG
    /// AC-20/AC-25 (RULE-14 in spec/rules.md): always true in a Debug build — the entry point
    /// itself is unconditional; AC-25's Release exclusion comes entirely from this whole
    /// property (and the `NavigationLink` below) being compiled out via `#if DEBUG`, not from
    /// any runtime check.
    var showsDemoModeEntryPoint: Bool { true }
    #endif

    var body: some View {
        let viewModel = dependencies.homeViewModel
        VStack(spacing: 16) {
            if viewModel.orphanedRideId != nil {
                HStack(alignment: .top) {
                    Label("Couldn't restore your last ride", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Discard", role: .destructive) {
                        Task { await viewModel.discardOrphanedRide() }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if viewModel.showsImportPrompt {
                Text("Import a route")
                    .font(.title2.bold())
                importButton("Choose GPX File")
            } else if let card = viewModel.routeCard {
                routeCard(card)
            }
            if viewModel.isImporting {
                ProgressView("Importing route…")
            }
            if let error = viewModel.importError {
                HStack(alignment: .top) {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button {
                        viewModel.dismissImportError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
            #if DEBUG
            NavigationLink("Demo Mode", value: HomeRoute.demo)
            #endif
        }
        .padding()
        .task { await dependencies.homeViewModel.refresh() }
        .onChange(of: dependencies.corridorImportCoordinator.pollingRouteIds) {
            Task { await dependencies.homeViewModel.refresh() }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [Self.gpxContentType]) { result in
            switch result {
            case .success(let fileURL):
                Task { await dependencies.homeViewModel.importGPX(from: fileURL) }
            case .failure:
                dependencies.homeViewModel.pickerFailed()
            }
        }
    }

    private func routeCard(_ card: RouteCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.title)
                .font(.title2.bold())
                .lineLimit(2)
            HStack(spacing: 16) {
                Label(card.distanceText, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                if let climbing = card.climbingText {
                    Label(climbing, systemImage: "arrow.up.right")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack {
                if card.corridor == .finding {
                    ProgressView()
                }
                Text(card.corridor.message)
                    .font(.subheadline)
                Spacer()
                if card.corridor.offersRetry {
                    Button("Retry") { Task { await dependencies.homeViewModel.retryCorridor() } }
                }
            }
            Button {
                Task { await dependencies.rideStartFlow.requestStart() }
            } label: {
                Text("Start Ride").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            HStack {
                Button("View map") { dependencies.appRouter.open(.corridorMap(routeId: card.routeId)) }
                Spacer()
                importButton("Import another route")
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private func importButton(_ title: String) -> some View {
        Button(title) { isImporterPresented = true }
            .disabled(dependencies.homeViewModel.isImporting)
    }
}

import RoutePersistence
import XCTest

@testable import CyclingCompanion

/// task-2.2 validation (RULE-8/RULE-16 in spec/rules.md, AC-2/AC-3).
final class HomeViewModelTests: XCTestCase {

    private func freshRouteStore() -> RouteStore {
        RouteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
    }

    private func freshPointer() -> CurrentRoutePointer {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return CurrentRoutePointer(defaults: defaults)
    }

    @MainActor
    func testNoPointerShowsTheImportPrompt() async {
        let viewModel = HomeViewModel(routeStore: freshRouteStore(), pointer: freshPointer())

        await viewModel.refresh()

        XCTAssertTrue(viewModel.showsImportPrompt)
        XCTAssertNil(viewModel.currentRoute)
    }

    @MainActor
    func testAStalePointerShowsTheImportPrompt() async {
        var pointer = freshPointer()
        pointer.routeId = "route-that-does-not-exist"
        let viewModel = HomeViewModel(routeStore: freshRouteStore(), pointer: pointer)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.showsImportPrompt)
        XCTAssertNil(viewModel.currentRoute)
    }

    @MainActor
    func testAValidPointerShowsTheCurrentRoute() async throws {
        let store = freshRouteStore()
        try await store.persist(
            routeId: "route-1", hash: "hash", totalDistanceMeters: 10_000, totalClimbingMeters: nil, points: [],
            pois: [], status: "ready")
        var pointer = freshPointer()
        pointer.routeId = "route-1"
        let viewModel = HomeViewModel(routeStore: store, pointer: pointer)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.showsImportPrompt)
        XCTAssertEqual(viewModel.currentRoute?.id, "route-1")
    }
}

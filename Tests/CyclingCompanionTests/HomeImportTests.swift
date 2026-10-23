import RoutePersistence
import XCTest

@testable import CyclingCompanion

@MainActor
private final class FakeImporter: RouteImporting {
    var error: Error?
    private(set) var imports = 0
    var gate: CheckedContinuation<Void, Never>?
    var holdsUntilReleased = false
    var retryInFlight: Set<String> = []
    var retryErrors: [String: CorridorActionError] = [:]

    nonisolated init() {}

    func importRouteThrowing(_ route: ImportedRoute) async throws -> Task<Void, Never> {
        imports += 1
        if holdsUntilReleased {
            await withCheckedContinuation { gate = $0 }
        }
        if let error { throw error }
        return Task {}
    }

    var pollingRouteIds: Set<String> = []
    private(set) var retries: [String] = []

    func isPolling(routeId: String) -> Bool { pollingRouteIds.contains(routeId) }

    func retry(routeId: String) async -> Task<Void, Never>? {
        retries.append(routeId)
        return nil
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// task-6.3 (RULE-23): AC-95 to AC-101.
final class HomeImportTests: XCTestCase {

    private func gpxFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var validGPX: String {
        """
        <?xml version="1.0"?><gpx version="1.1"><trk><name>Canal loop</name><trkseg>
        <trkpt lat="52.0" lon="13.0"></trkpt><trkpt lat="52.01" lon="13.0"></trkpt><trkpt lat="52.02" lon="13.0"></trkpt>
        </trkseg></trk></gpx>
        """
    }

    @MainActor
    private func viewModel(_ importer: FakeImporter) -> (HomeViewModel, CurrentRoutePointer) {
        let pointer = CurrentRoutePointer(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        pointer.routeId = "existing-route"
        let store = RouteStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        return (HomeViewModel(routeStore: store, pointer: pointer, importer: importer), pointer)
    }

    @MainActor
    func testAValidFileIsUploaded() async throws {
        let importer = FakeImporter()
        let (viewModel, _) = viewModel(importer)

        await viewModel.importGPX(from: try gpxFile(validGPX))

        XCTAssertEqual(importer.imports, 1)
        XCTAssertNil(viewModel.importError)
        XCTAssertFalse(viewModel.isImporting)
    }

    /// AC-95/AC-96: in progress while uploading; a second import is ignored.
    @MainActor
    func testImportingShowsProgressAndBlocksASecondImport() async throws {
        let importer = FakeImporter()
        importer.holdsUntilReleased = true
        let (viewModel, _) = viewModel(importer)
        let file = try gpxFile(validGPX)

        let first = Task { await viewModel.importGPX(from: file) }
        while importer.gate == nil { await Task.yield() }
        XCTAssertTrue(viewModel.isImporting)
        await viewModel.importGPX(from: file)
        XCTAssertEqual(importer.imports, 1, "the second import is ignored")

        importer.release()
        await first.value
        XCTAssertFalse(viewModel.isImporting)
    }

    /// AC-97.
    @MainActor
    func testPickerFailure() {
        let (viewModel, pointer) = viewModel(FakeImporter())

        viewModel.pickerFailed()

        XCTAssertEqual(viewModel.importError, .pickerFailed)
        XCTAssertEqual(pointer.routeId, "existing-route")
    }

    /// AC-98: unparseable, or no track points — and nothing is uploaded.
    @MainActor
    func testUnreadableFiles() async throws {
        for contents in ["this is not xml", #"<?xml version="1.0"?><gpx version="1.1"></gpx>"#] {
            let importer = FakeImporter()
            let (viewModel, pointer) = viewModel(importer)

            await viewModel.importGPX(from: try gpxFile(contents))

            XCTAssertEqual(viewModel.importError, .unreadableGPX)
            XCTAssertEqual(importer.imports, 0)
            XCTAssertEqual(pointer.routeId, "existing-route")
        }
    }

    /// AC-99 to AC-101: each network failure gets its own message; the current route stays.
    @MainActor
    func testNetworkFailuresAreTold() async throws {
        let cases: [(Error, ImportError)] = [
            (URLError(.notConnectedToInternet), .noConnection),
            (URLError(.timedOut), .noConnection),
            (AuthStubClientError.unexpectedResponse, .authFailed),
            (CorridorPollingError.rejected(statusCode: 401), .authFailed),
            (CorridorPollingError.rejected(statusCode: 403), .authFailed),
            (CorridorPollingError.rejected(statusCode: 500), .backendRejected),
            (CorridorPollingError.unexpectedResponse, .backendRejected),
        ]
        for (error, expected) in cases {
            let importer = FakeImporter()
            importer.error = error
            let (viewModel, pointer) = viewModel(importer)

            await viewModel.importGPX(from: try gpxFile(validGPX))

            XCTAssertEqual(viewModel.importError, expected, "\(error)")
            XCTAssertEqual(pointer.routeId, "existing-route")
        }
    }

    func testEveryErrorHasItsOwnMessage() {
        let all: [ImportError] = [.pickerFailed, .unreadableGPX, .noConnection, .authFailed, .backendRejected]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
    }

    @MainActor
    func testAnErrorCanBeDismissed() {
        let (viewModel, _) = viewModel(FakeImporter())
        viewModel.pickerFailed()

        viewModel.dismissImportError()

        XCTAssertNil(viewModel.importError)
    }
}

/// A rejected import keeps its HTTP status, so 401/403 can be told apart.
final class CorridorImportRejectionTests: XCTestCase {
    private struct StatusTransport: HTTPTransport {
        let status: Int

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let body = request.url!.path.hasSuffix("sign-in")
                ? #"{"token":"t","riderId":"11111111-1111-1111-1111-111111111111"}"# : "{}"
            let code = request.url!.path.hasSuffix("sign-in") ? 200 : status
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testARejectedImportCarriesItsStatus() async throws {
        let transport = StatusTransport(status: 401)
        let auth = AuthStubClient(baseURL: URL(string: "https://backend.example.com")!, transport: transport)
        _ = try await auth.signIn(placeholderIdentity: "x")
        let service = CorridorPollingService(
            baseURL: URL(string: "https://backend.example.com")!, authClient: auth, transport: transport)
        let route = ImportedRoute(points: [], totalDistanceMeters: 0, totalClimbingMeters: nil, hash: "h")

        do {
            _ = try await service.importRoute(route)
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? CorridorPollingError, .rejected(statusCode: 401))
        }
    }
}

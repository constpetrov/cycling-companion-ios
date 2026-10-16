import XCTest

@testable import CyclingCompanion

final class BackendConfigurationTests: XCTestCase {
    func testSimulatorKeepsTheLocalTunnelDefault() throws {
        let configuration = try BackendConfiguration.load(info: [:], allowsLoopback: true)
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://localhost:8080")
        XCTAssertNil(configuration.demoAccessToken)
    }

    func testPhysicalDeviceDoesNotSilentlyConnectToItself() {
        XCTAssertThrowsError(try BackendConfiguration.load(info: [:], allowsLoopback: false))
    }

    func testInstalledAppReadsTheHTTPSOriginAndDemoKeyFromItsBundle() throws {
        let configuration = try BackendConfiguration.load(info: [
            "CyclingCompanionBackendBaseURL": "https://api.example.com",
            "CyclingCompanionDemoAccessToken": "test-demo-key",
        ], allowsLoopback: false)
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://api.example.com")
        XCTAssertEqual(configuration.demoAccessToken, "test-demo-key")
    }

    func testRejectsRemoteHTTPAndAddressesContainingCredentialsOrAPIPaths() {
        for address in ["http://api.example.com", "https://user:password@api.example.com",
                        "https://api.example.com/api/v1", "https://api.example.com?key=secret"] {
            XCTAssertThrowsError(try BackendConfiguration.load(info: [
                "CyclingCompanionBackendBaseURL": address,
                "CyclingCompanionDemoAccessToken": "test-demo-key",
            ], allowsLoopback: false))
        }
    }

    func testRejectsAnUnexpandedGatewayKey() {
        XCTAssertThrowsError(try BackendConfiguration.load(info: [
            "CyclingCompanionBackendBaseURL": "https://api.example.com",
            "CyclingCompanionDemoAccessToken": "$(CC_DEMO_ACCESS_TOKEN)",
        ], allowsLoopback: false))
    }
}

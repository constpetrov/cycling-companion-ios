import XCTest

@testable import CyclingCompanion

/// Milestone 10 task-4.1 (RULE-35, RULE-36): AC-115's storage half and AC-135.
final class TokenStoreTests: XCTestCase {

    private var keychain: KeychainTokenStore!

    override func setUp() {
        super.setUp()
        // Its own item, so tests never touch the app's real token.
        keychain = KeychainTokenStore(service: "com.cyclingcompanion.tests." + UUID().uuidString)
    }

    override func tearDown() {
        try? keychain.delete()
        super.tearDown()
    }

    func testTheKeychainStoreRoundTripsAndOverwrites() throws {
        XCTAssertNil(try keychain.load())

        try keychain.save("first-token")
        XCTAssertEqual(try keychain.load(), "first-token")

        try keychain.save("second-token")
        XCTAssertEqual(try keychain.load(), "second-token")

        try keychain.delete()
        XCTAssertNil(try keychain.load())
    }

    func testDeletingAMissingItemIsFine() throws {
        XCTAssertNoThrow(try keychain.delete())
    }

    func testTheInMemoryStoreRoundTrips() throws {
        let store = InMemoryTokenStore(token: "seed")
        XCTAssertEqual(try store.load(), "seed")
        try store.save("next")
        XCTAssertEqual(try store.load(), "next")
        try store.delete()
        XCTAssertNil(try store.load())
    }

    private func freshDefaults() -> UserDefaults {
        let name = "first-launch-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// AC-135.
    func testTheFirstLaunchDeletesALeftoverTokenAndSetsTheFlag() throws {
        let defaults = freshDefaults()
        let store = InMemoryTokenStore(token: "left-from-a-previous-install")

        FirstLaunchCheck.run(defaults: defaults, tokenStore: store)

        XCTAssertNil(try store.load())
        XCTAssertTrue(defaults.bool(forKey: FirstLaunchCheck.defaultsKey))
    }

    func testLaterLaunchesKeepTheToken() throws {
        let defaults = freshDefaults()
        defaults.set(true, forKey: FirstLaunchCheck.defaultsKey)
        let store = InMemoryTokenStore(token: "current-session")

        FirstLaunchCheck.run(defaults: defaults, tokenStore: store)

        XCTAssertEqual(try store.load(), "current-session")
    }

    func testALockedKeychainLeavesTheFlagUnsetForTheNextLaunch() {
        let defaults = freshDefaults()

        FirstLaunchCheck.run(defaults: defaults, tokenStore: LockedTokenStore())

        XCTAssertFalse(defaults.bool(forKey: FirstLaunchCheck.defaultsKey))
    }
}

/// A store whose device is never unlocked.
struct LockedTokenStore: TokenStore {
    func load() throws -> String? { throw TokenStoreError.locked }
    func save(_ token: String) throws { throw TokenStoreError.locked }
    func delete() throws { throw TokenStoreError.locked }
}

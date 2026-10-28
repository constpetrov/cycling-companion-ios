import Foundation
import os

/// Where the refresh token lives between launches (RULE-35 in milestone 10's rules.md). The access
/// token never goes here: it stays in `AuthSession`'s memory.
protocol TokenStore: Sendable {
    /// The stored refresh token, or `nil` when there is none. Throws `TokenStoreError.locked` while
    /// the device hasn't been unlocked since boot; that is not "signed out" (RULE-34).
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

extension TokenStore {
    /// Whether a refresh token is stored. A locked Keychain counts as yes: the token is still there.
    var hasStoredToken: Bool {
        do {
            return try load() != nil
        } catch {
            return true
        }
    }
}

enum TokenStoreError: Error, Equatable {
    /// `errSecInteractionNotAllowed`: the token is fine, the device just isn't unlocked yet.
    case locked
    case unexpected(OSStatus)
}

/// A `TokenStore` that keeps the token in memory, for tests and UI-test fixtures.
final class InMemoryTokenStore: TokenStore {
    private let token: OSAllocatedUnfairLock<String?>

    init(token: String? = nil) {
        self.token = OSAllocatedUnfairLock(initialState: token)
    }

    func load() throws -> String? {
        token.withLock { $0 }
    }

    func save(_ token: String) throws {
        self.token.withLock { $0 = token }
    }

    func delete() throws {
        token.withLock { $0 = nil }
    }
}

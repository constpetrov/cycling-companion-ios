import Foundation
import Security

/// The refresh token as one generic-password Keychain item (RULE-35 in milestone 10's rules.md).
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: rides run with the phone locked, so the token
/// must be readable after the first unlock, and `ThisDeviceOnly` keeps it out of backups. Writes
/// update the existing item and add one only when there is none, never delete-then-add.
/// `errSecInteractionNotAllowed` is reported as `.locked` and never deletes the token.
struct KeychainTokenStore: TokenStore {
    static let defaultService = "com.cyclingcompanion.auth"
    static let defaultAccount = "refresh-token"

    private let service: String
    private let account: String

    init(service: String = Self.defaultService, account: String = Self.defaultAccount) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw TokenStoreError.locked
        default:
            throw TokenStoreError.unexpected(status)
        }
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add.merge(update) { _, new in new }
            let added = SecItemAdd(add as CFDictionary, nil)
            if added == errSecInteractionNotAllowed { throw TokenStoreError.locked }
            guard added == errSecSuccess else { throw TokenStoreError.unexpected(added) }
        case errSecInteractionNotAllowed:
            throw TokenStoreError.locked
        default:
            throw TokenStoreError.unexpected(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecInteractionNotAllowed:
            throw TokenStoreError.locked
        default:
            throw TokenStoreError.unexpected(status)
        }
    }
}

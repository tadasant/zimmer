#if canImport(Security)
import Foundation
import Security
import ZimmerKit
import os

/// The sign-in, in the Keychain: the server and the OAuth tokens as one JSON item.
///
/// `AfterFirstUnlockThisDeviceOnly`: readable by a push or a CarPlay connection that wakes
/// the app while the phone is locked, never restored onto another device from a backup.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account = "zimmer.sign-in"
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "signin")

    public init(service: String = "com.tadasant.zimmer") {
        self.service = service
    }

    public func load() -> StoredSignIn? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { log.error("keychain read failed: \(status, privacy: .public)") }
            return nil
        }
        return try? JSONDecoder().decode(StoredSignIn.self, from: data)
    }

    public func save(_ signIn: StoredSignIn?) {
        SecItemDelete(baseQuery() as CFDictionary)
        guard let signIn, let data = try? JSONEncoder().encode(signIn) else { return }
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { log.error("keychain write failed: \(status, privacy: .public)") }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif

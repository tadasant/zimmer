#if canImport(Security)
import Foundation
import Security
import ZimmerKit
import os

/// One generic-password Keychain item.
///
/// `AfterFirstUnlockThisDeviceOnly`: readable by a push or a CarPlay connection that wakes
/// the app while the phone is locked, never restored onto another device from a backup.
struct KeychainItem: Sendable {
    let service: String
    let account: String
    private static let log = Logger(subsystem: "com.tadasant.zimmer", category: "signin")

    func read() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { Self.log.error("keychain read of \(account, privacy: .public) failed: \(status, privacy: .public)") }
            return nil
        }
        return data
    }

    func write(_ data: Data?) {
        SecItemDelete(baseQuery() as CFDictionary)
        guard let data else { return }
        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess { Self.log.error("keychain write of \(account, privacy: .public) failed: \(status, privacy: .public)") }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The Zimmer sign-in — the deployment's origins and the OAuth tokens — as one JSON item.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let item: KeychainItem

    public init(service: String = "com.tadasant.zimmer") {
        item = KeychainItem(service: service, account: "zimmer.sign-in")
    }

    public func load() -> StoredSignIn? {
        item.read().flatMap { try? JSONDecoder().decode(StoredSignIn.self, from: $0) }
    }

    public func save(_ signIn: StoredSignIn?) {
        item.write(signIn.flatMap { try? JSONEncoder().encode($0) })
    }
}

/// The edge's Cloudflare Access JWT, kept apart from Zimmer's own tokens.
public final class KeychainEdgeTokenStore: EdgeTokenStore, @unchecked Sendable {
    private let item: KeychainItem

    public init(service: String = "com.tadasant.zimmer") {
        item = KeychainItem(service: service, account: "zimmer.edge-access-token")
    }

    public func load() -> String? {
        item.read().map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func save(_ token: String?) {
        item.write(token.map { Data($0.utf8) })
    }
}
#endif

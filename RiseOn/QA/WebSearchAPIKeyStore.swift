import Foundation
import Security

/// Secure storage for the optional web-search API key (东方财富妙想 mx-search,
/// `MX_APIKEY`), used by the `web_search` tool round in every direct-HTTP
/// `LLMService` conformer when the user has enabled 联网检索 but their chat
/// model isn't itself search-augmented.
///
/// Same Keychain design as `LLMAPIKeyStore` (device-only, unlocked-only,
/// never logged) — a separate service identifier so the two keys are stored
/// and deleted independently.
public enum WebSearchAPIKeyStore {
    private static let service = "com.riseon.websearch.apikey"
    private static let account = "default"

    public enum KeyStoreError: Error {
        case invalidKeyEncoding
        case unexpectedStatus(OSStatus)
    }

    public static func save(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeyStoreError.invalidKeyEncoding
        }
        SecItemDelete(baseQuery() as CFDictionary)
        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    public static func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    public static func exists() throws -> Bool {
        try load() != nil
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

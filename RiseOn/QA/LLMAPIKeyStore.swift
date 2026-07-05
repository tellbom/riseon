import Foundation
import Security

/// Secure storage for the user's LLM API key (task.md S3.2, plan.md §9/§13).
///
/// Backed by the iOS/watchOS Keychain — **never** `UserDefaults`. Placed in
/// `QA/` (not `Workspace/`) because its only consumer is `LLMService` (S10);
/// it's built now, ahead of `LLMService`, per task.md's own sequencing.
///
/// - Accessibility is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: the key
///   never syncs to iCloud Keychain (this is a single-device, personal-use
///   app) and is only accessible while the device is unlocked, which is
///   always true when `LLMService` calls out — LLM inference only happens on
///   foreground user interaction (plan.md §12), never in the background.
/// - Nothing in this type ever logs the key value — callers must keep it that
///   way too (task.md S3.2's "日志不打印 Key").
public enum LLMAPIKeyStore {
    private static let service = "com.riseon.llm.apikey"
    private static let account = "default"

    public enum KeyStoreError: Error {
        case invalidKeyEncoding
        case unexpectedStatus(OSStatus)
    }

    /// Saves (or overwrites) the API key.
    public static func save(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeyStoreError.invalidKeyEncoding
        }

        // Upsert: clear any existing item first, then add fresh. Simpler and
        // less error-prone than branching on SecItemUpdate vs SecItemAdd.
        SecItemDelete(baseQuery() as CFDictionary)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    /// Returns the stored key, or `nil` if none has been saved.
    public static func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeyStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// Removes the stored key. Idempotent — does not throw if nothing was stored.
    public static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    /// Convenience check that avoids callers having to unwrap `load()` just
    /// to test presence (e.g. for a settings-screen "Key configured" badge).
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

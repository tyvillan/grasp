import Foundation
#if canImport(Security)
import Security
#endif

/// Where the cloud API key lives: the Keychain on Apple platforms, never the
/// library database (which syncs to the server) or plain preferences.
///
/// Written as iCloud-synchronizable so the iPhone gets the key without a
/// second paste. That needs the data-protection keychain, which an app
/// without a keychain entitlement can't use; the write then falls back to
/// the login keychain, which doesn't sync. Reads look in both.
///
/// Windows has no Keychain; until it stores the key its own way (DPAPI),
/// `read()` returns nil there and Cloud mode stays unavailable.
public enum AIKeyStore {
    static let service = "com.tyvillan.grasp.ai"
    static let account = "gemini"

    /// Cleans up what was pasted and says what's wrong with it, if anything.
    /// Keys get pasted with a `GEMINI_API_KEY=` prefix, wrapped in quotes,
    /// or truncated with an ellipsis; any of those is rejected by Google,
    /// and non-ASCII characters can't even be sent in a header.
    public static func sanitize(_ raw: String) -> (key: String, problem: String?) {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") { key = String(key.dropFirst(7)) }
        if let equals = key.lastIndex(of: "="), key[..<equals].allSatisfy({ $0.isLetter || $0 == "_" }) {
            key = String(key[key.index(after: equals)...])
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespacesAndNewlines))
        if key.isEmpty { return (key, nil) }
        if key.contains(where: { $0.isWhitespace }) {
            return (key, "That has spaces or line breaks in it. A Gemini key is one unbroken string.")
        }
        if !key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) {
            return (key, "That contains a character a key can't have, like an ellipsis (…) from a shortened display. Copy the full key.")
        }
        if key.count < 20 {
            return (key, "That's too short to be a Gemini key. Copy the full key.")
        }
        return (key, nil)
    }

    /// Why `read()` has no key, for Settings to say rather than showing
    /// "no key" for every cause.
    public enum KeyState: Equatable, Sendable {
        case missing
        case ready
        /// An item is stored but holds nothing (e.g. a copy command whose
        /// source variable didn't exist).
        case empty
        /// An item is stored but the system wouldn't hand it over, e.g.
        /// access was declined. Carries the OSStatus.
        case unreadable(Int32)
    }

    public static func read() -> String? { fetch().key }

    public static func state() -> KeyState {
        let (key, status, found) = fetch()
        if key != nil { return .ready }
        if found { return .empty }
        #if canImport(Security)
        return status == errSecItemNotFound || status == errSecSuccess ? .missing : .unreadable(status)
        #else
        return .missing
        #endif
    }

    /// `found`: an item came back, whatever it held.
    private static func fetch() -> (key: String?, status: Int32, found: Bool) {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        #if os(macOS)
        if status != errSecSuccess {
            query[kSecUseDataProtectionKeychain as String] = true
            let second = SecItemCopyMatching(query as CFDictionary, &result)
            // Not-found from the second place mustn't hide why the first failed.
            if second == errSecSuccess || status == errSecItemNotFound { status = second }
        }
        #endif
        guard status == errSecSuccess, let data = result as? Data else { return (nil, status, false) }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (key.isEmpty ? nil : key, status, true)
        #else
        return (nil, -1, false)
        #endif
    }

    /// Saves (or, for an empty key, removes) the key. Returns whether it
    /// was stored.
    @discardableResult
    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        delete()
        guard !trimmed.isEmpty else { return true }
        #if canImport(Security)
        let data = Data(trimmed.utf8)
        var synced: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "GRASP Gemini API key",
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        #if os(macOS)
        synced[kSecUseDataProtectionKeychain as String] = true
        #endif
        if SecItemAdd(synced as CFDictionary, nil) == errSecSuccess { return true }
        let local: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "GRASP Gemini API key",
            kSecValueData as String: data,
        ]
        return SecItemAdd(local as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    public static func delete() {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(query as CFDictionary)
        #endif
        #endif
    }
}

#if os(macOS)
import Foundation
import Security

/// Optional convenience for an unlocked Mac: the vault password is kept in the
/// file-based login keychain so the app can reopen the vault without retyping it.
///
/// Only ever written after a successful unlock, and only while the user has the
/// "remember password" preference enabled. The item stays bound to the vault
/// directory, so switching directories never reuses another vault's password.
enum KeychainStore {
    static let service = "com.liuchzzyy.tas"

    /// The file-based keychain is the only available store for an ad-hoc signed
    /// app: the data protection keychain requires keychain-access-group entitlements.
    private static let storeKey = kSecUseDataProtectionKeychain as String

    /// Normalised so the same directory always maps to the same account even when
    /// reached through a system symlink such as /var -> /private/var.
    static func account(for directory: URL) -> String {
        // resolvingSymlinksInPath cannot resolve a nonexistent leaf: resolve
        // its existing parent first, then append the final directory name.
        return directory.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(directory.lastPathComponent).standardizedFileURL.path
    }

    private static func base(_ directory: URL, data: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(for: directory),
                                    storeKey: false]
        if data { query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne }
        return query
    }

    @discardableResult
    static func save(_ password: String, for directory: URL) -> Bool {
        guard !password.isEmpty, let encoded = password.data(using: .utf8) else { return false }
        var attributes = base(directory)
        attributes[kSecValueData as String] = encoded
        attributes[kSecAttrLabel as String] = "TAS — encrypted vault (加密文件库)"
        let result = SecItemAdd(attributes as CFDictionary, nil)
        if result == errSecSuccess { return true }
        guard result == errSecDuplicateItem else { return false }
        return SecItemUpdate(base(directory) as CFDictionary,
                             [kSecValueData as String: encoded] as CFDictionary) == errSecSuccess
    }

    /// Returns the stored password, or nil when nothing usable is stored. A failed
    /// lookup is never distinguished from an absent item, so callers fall back to
    /// the ordinary unlock form.
    static func read(for directory: URL) -> String? {
        var item: CFTypeRef?
        guard SecItemCopyMatching(base(directory, data: true) as CFDictionary, &item) == errSecSuccess,
              let encoded = item as? Data,
              let value = String(data: encoded, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func exists(for directory: URL) -> Bool { read(for: directory) != nil }

    static func delete(for directory: URL) { SecItemDelete(base(directory) as CFDictionary) }
}
#endif

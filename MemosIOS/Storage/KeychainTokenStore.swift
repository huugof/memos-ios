import Foundation
import Security
import OSLog

private let keychainLogger = Logger(subsystem: "com.hugo.MemosIOS", category: "Keychain")

enum KeychainTokenStore {
    private static let service = "com.hugo.MemosIOS"
    private static let account = "memos.api.token"

    static func setToken(_ token: String) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw KeychainError.emptyToken
        }

        let data = Data(trimmedToken.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // Try update first (atomic); fall back to add when the item doesn't exist yet.
        let updateAttribs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttribs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    static func getToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                keychainLogger.warning("Keychain read failed — token unavailable")
            }
            return ""
        }

        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            keychainLogger.error("Keychain data could not be decoded as UTF-8 string")
            return ""
        }

        return token
    }

    static func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

enum KeychainError: Error {
    case emptyToken
    case unexpectedStatus(OSStatus)
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Token cannot be empty."
        case .unexpectedStatus(let status):
            return "Keychain operation failed (\(status))."
        }
    }
}

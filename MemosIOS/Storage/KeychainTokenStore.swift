import Foundation
import Security

enum KeychainTokenStore {
    private static let service = "com.hugo.MemosIOS"
    private static let account = "memos.api.token"
    #if targetEnvironment(simulator)
    private static let simulatorTokenKey = "simulator.memos.api.token"
    #endif

    static func setToken(_ token: String) throws {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw KeychainError.emptyToken
        }

        #if targetEnvironment(simulator)
        UserDefaults.standard.set(trimmedToken, forKey: simulatorTokenKey)
        return
        #else
        let data = Data(trimmedToken.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(deleteStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
        #endif
    }

    static func getToken() -> String {
        #if targetEnvironment(simulator)
        return UserDefaults.standard.string(forKey: simulatorTokenKey) ?? ""
        #else
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
            return ""
        }

        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            return ""
        }

        return token
        #endif
    }

    static func deleteToken() throws {
        #if targetEnvironment(simulator)
        UserDefaults.standard.removeObject(forKey: simulatorTokenKey)
        return
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
        #endif
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

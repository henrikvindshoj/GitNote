import Foundation
import Security

struct KeychainStore: Sendable {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case tokenNotPersisted

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                if status == -34_018 {
                    "GitNote cannot access Keychain because this build is not code-signed. Run a normally signed build from Xcode."
                } else {
                    "Keychain returned status \(status)."
                }
            case .tokenNotPersisted:
                "GitHub authorized GitNote, but the token could not be read back from Keychain."
            }
        }
    }

    private let service: String
    private let account: String

    init(
        service: String = "com.henrikvindshoj.GitNote",
        account: String = "github-token"
    ) {
        self.service = service
        self.account = account
    }

    func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        let value = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: value]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = value
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(createStatus)
        }
    }

    func deleteToken() throws {
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

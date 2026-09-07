import Foundation
import Security
import AnyWhereCore

enum PackConfiguration {
    static func store() -> PackConfigurationStore {
        PackConfigurationStore(directory: AppPaths.configDirectory().appendingPathComponent("PackConfigurations"),
                               secrets: KeychainPackSecrets())
    }
}

struct KeychainPackSecrets: PackSecretStore {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.anywhere.pack-settings",
         kSecAttrAccount as String: account]
    }

    struct AccessError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            String(format: String(localized: "packConfig.keychainError"), status)
        }
    }

    func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw AccessError(status: status) }
        return value
    }

    func write(_ value: String?, account: String) throws {
        let request = query(account)
        guard let value else {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccessError(status: status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AccessError(status: status) }
    }
}

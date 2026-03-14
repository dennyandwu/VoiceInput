import Foundation
import Security

/// 简单的 Keychain 存取封装
/// 使用 Data Protection Keychain (kSecUseDataProtectionKeychain)
/// 避免 ad-hoc 签名应用弹出 Keychain 授权弹窗
enum KeychainHelper {

    static func set(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 先删除旧值
        delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            fputs("[Keychain] 写入失败: \(status)\n", stderr)
        }
    }

    static func get(service: String, account: String) -> String? {
        // 优先从 Data Protection Keychain 读取
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        // Fallback: 从 legacy Keychain 读取（v3.0.2 及之前存的 key）
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var legacyResult: AnyObject?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)

        if legacyStatus == errSecSuccess, let data = legacyResult as? Data,
           let value = String(data: data, encoding: .utf8) {
            // 自动迁移到 Data Protection Keychain
            set(value, service: service, account: account)
            // 删除 legacy 条目
            SecItemDelete(legacyQuery as CFDictionary)
            fputs("[Keychain] 已从 legacy keychain 迁移: \(account)\n", stderr)
            return value
        }

        return nil
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)

        // 也清理旧的 legacy keychain 条目（迁移用）
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}

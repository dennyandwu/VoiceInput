import Foundation
import Security

/// 简单的 Keychain 存取封装
/// 优先使用 Data Protection Keychain，ad-hoc 签名失败时自动降级到 legacy Keychain
enum KeychainHelper {

    /// 尝试写入 Data Protection Keychain，失败则降级到 legacy Keychain
    static func set(_ value: String, service: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 先删除旧值（两个域都清理）
        delete(service: service, account: account)

        // 尝试 Data Protection Keychain
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]

        let dpStatus = SecItemAdd(dpQuery as CFDictionary, nil)
        if dpStatus == errSecSuccess {
            fputs("[Keychain] 写入成功 (Data Protection): \(account)\n", stderr)
            return
        }

        // Data Protection 失败（-34018 = errSecMissingEntitlement，ad-hoc 签名常见）
        // 降级到 legacy Keychain
        fputs("[Keychain] Data Protection 写入失败 (\(dpStatus))，降级到 legacy keychain\n", stderr)

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let legacyStatus = SecItemAdd(legacyQuery as CFDictionary, nil)
        if legacyStatus == errSecSuccess {
            fputs("[Keychain] 写入成功 (legacy): \(account)\n", stderr)
        } else {
            fputs("[Keychain] legacy 写入也失败: \(legacyStatus)\n", stderr)
        }
    }

    /// 优先从 Data Protection Keychain 读取，失败则从 legacy Keychain 读取
    static func get(service: String, account: String) -> String? {
        // 1. 尝试 Data Protection Keychain
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]

        var result: AnyObject?
        let dpStatus = SecItemCopyMatching(dpQuery as CFDictionary, &result)

        if dpStatus == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        // 2. Fallback: legacy Keychain
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
            return value
        }

        return nil
    }

    /// 删除两个域的条目
    static func delete(service: String, account: String) {
        // Data Protection Keychain
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(dpQuery as CFDictionary)

        // Legacy Keychain
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}

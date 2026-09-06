import Foundation
import Security

/// 密钥只在发起请求和编辑设置时短暂进入内存，不写入偏好设置或日志。
/// 使用固定 service/account，使升级版本后仍能读取同一钥匙串项目。
@MainActor
enum APIKeyStore {
    private static func query(account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.simpleview.ai-api-key",
        kSecAttrAccount as String: account
    ] }

    static func load(account: String = "default") throws -> String {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        if let data = result as? Data, let key = String(data: data, encoding: .utf8) {
            // 旧版本可能仍有副本；已有钥匙串值时以钥匙串为准。
            if account == "default" { UserDefaults.standard.removeObject(forKey: "aiAPIKey") }
            return key
        }
        if account == "default", let legacy = UserDefaults.standard.string(forKey: "aiAPIKey"), !legacy.isEmpty {
            try save(legacy, account: account)
            return legacy
        }
        return ""
    }

    static func save(_ key: String, account: String = "default") throws {
        let query = query(account: account)
        let status: OSStatus
        if key.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        } else {
            let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updated == errSecItemNotFound {
                var item = query.merging(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = updated }
            guard status == errSecSuccess else { throw failure(status) }
        }
        // 先写钥匙串、后删旧值。锁定/拒绝访问等失败不能导致旧凭据丢失。
        if account == "default" { UserDefaults.standard.removeObject(forKey: "aiAPIKey") }
    }

    private static func failure(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "钥匙串访问失败：" + (SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)")
        ])
    }
}

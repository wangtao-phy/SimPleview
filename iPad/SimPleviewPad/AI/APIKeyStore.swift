import Foundation
import Security

/// 密钥只在发起请求和编辑设置时短暂进入内存，不写入偏好设置或日志。
/// 使用固定 service/account，使升级版本后仍能读取同一钥匙串项目。
@MainActor
enum APIKeyStore {
    private static func query(account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.tau.SimPleview.pad.ai-key",
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
            return key
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

    }

    private static func failure(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "钥匙串访问失败：" + (SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)")
        ])
    }
}

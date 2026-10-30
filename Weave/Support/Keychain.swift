import Foundation
import Security

/// 极小的 Keychain 包装。原来 API Key 明文躺在 UserDefaults 里，
/// 任何能做设备备份或读到容器 plist 的途径都能直接看到它。
/// 这里只存一个字符串，用 generic password 项，service 取 bundle id。
enum Keychain {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "app.weave.ios"
    }

    /// 读不到（没存过、或被拒绝）都返回 nil，不抛错：调用方只需要「有没有值」
    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// 空字符串等同于删除，避免 Keychain 里留一条空记录
    @discardableResult
    static func set(_ value: String?, forKey key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // 只在本机解锁后可读：不随 iCloud 钥匙串同步，也不需要 Face ID
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insert = base
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

import Foundation
import Security

// Both targets use the app's original default Keychain group, preserving installed sessions.
// Only the destination is added here; session tokens stay in KeychainSessionStore.
struct ShareDestinationStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "family.yearly.share-destination",
         kSecAttrAccount as String: "site"]
    }
    func read() throws -> SiteOrigin? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let address = String(data: data, encoding: .utf8) else {
            throw UploadFailure(message: "无法读取分享目标，请解锁设备并打开 yearly 后重试。")
        }
        return SiteOrigin(address)
    }
    func save(_ address: String) throws {
        guard let site = SiteOrigin(address) else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw UploadFailure(message: "无法清除相册分享的站点设置。")
            }
            return
        }
        let changes: [String: Any] = [kSecValueData as String: Data(site.url.absoluteString.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw UploadFailure(message: "无法更新相册分享的站点设置，请解锁设备后重试。")
        }
    }
}

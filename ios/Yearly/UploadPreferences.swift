import Foundation
import CryptoKit

// Only profile IDs are preferences. Login credentials remain exclusively in Keychain.
struct UploadProfilePreferences {
    let defaults: UserDefaults
    private let key: String
    init(site: SiteOrigin, ownerID: Int, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let scope = "\(site.url.absoluteString)|\(ownerID)"
        key = "yearly.upload.profiles." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func save(_ ids: Set<Int>) {
        let valid = ids.filter { $0 > 0 }.sorted()
        if let data = try? JSONEncoder().encode(valid) { defaults.set(data, forKey: key) }
    }
    func restore(validIDs: Set<Int>) -> Set<Int> {
        let remembered: [Int]
        if let data = defaults.data(forKey: key) {
            remembered = (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        } else { remembered = [] }
        let selection = Set(remembered).intersection(validIDs)
        save(selection) // Retire deleted profiles only after a successful profile list fetch.
        return selection
    }
}

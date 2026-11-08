import Foundation

@main struct UploadPreferencesTests {
    static func main() throws {
        let suite = "yearly.synthetic.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let site = SiteOrigin("https://family.invalid/yearly/")!
        let preferences = UploadProfilePreferences(site: site, ownerID: 1, defaults: defaults)
        precondition(preferences.restore(validIDs: [1, 2, 3], fallback: [2, 3]) == [2, 3])
        preferences.save([1, 3])
        let restarted = UploadProfilePreferences(site: SiteOrigin("https://family.invalid/yearly")!, ownerID: 1, defaults: UserDefaults(suiteName: suite)!)
        precondition(restarted.restore(validIDs: [1, 2, 3], fallback: [2]) == [1, 3])
        restarted.save([])
        precondition(preferences.restore(validIDs: [1, 2, 3], fallback: [2]) == [])
        preferences.save([1, 3])
        precondition(preferences.restore(validIDs: [1, 2]) == [1])
        precondition(preferences.restore(validIDs: [1, 2, 3]) == [1])
        let otherUser = UploadProfilePreferences(site: site, ownerID: 2, defaults: defaults)
        precondition(otherUser.restore(validIDs: [1, 2, 3]) == [])
        let otherPath = UploadProfilePreferences(site: SiteOrigin("https://family.invalid/other/")!, ownerID: 1, defaults: defaults)
        precondition(otherPath.restore(validIDs: [1, 2, 3]) == [])
        let otherHost = UploadProfilePreferences(site: SiteOrigin("https://another.invalid/yearly/")!, ownerID: 1, defaults: defaults)
        precondition(otherHost.restore(validIDs: [1, 2, 3]) == [])
        precondition(preferences.restore(validIDs: [1, 2, 3]) == [1])
        print("Upload preference checks passed: restart, multi-profile selection, explicit empty choice, deleted profiles, legacy batch and account/site/path isolation.")
    }
}

import Foundation

/// Only the configured HTTPS origin may receive the native photo bridge.
struct SiteOrigin {
    let url: URL

    init?(_ address: String) {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil,
              (1...65535).contains(parts.port ?? 443) else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        parts.path = "/"
        guard let url = parts.url else { return nil }
        self.url = url
    }

    func contains(_ candidate: URL?) -> Bool {
        guard let candidate, candidate.user == nil, candidate.password == nil else { return false }
        return candidate.scheme?.lowercased() == "https"
            && candidate.host?.lowercased() == url.host?.lowercased()
            && (candidate.port ?? 443) == (url.port ?? 443)
    }

    static func isAttachmentURL(_ url: URL) -> Bool {
        guard AppConfiguration.httpsURL(url.absoluteString) != nil else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name.lowercased() == "response-content-disposition"
                && ($0.value ?? "").lowercased().hasPrefix("attachment")
        } == true
    }
}

enum AppConfiguration {
    static func httpsURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              (1...65535).contains(parts.port ?? 443) else { return nil }
        return parts.url
    }

    static func url(for key: String) -> URL? {
        httpsURL(Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
    }

    static var defaultSite: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "YearlyDefaultSiteURL") as? String ?? ""
        return SiteOrigin(value)?.url.absoluteString ?? ""
    }
}

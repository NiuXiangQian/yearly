import Foundation

/// Scope the native bridge to the HTTPS origin and configured installation path.
struct SiteOrigin {
    let url: URL
    let origin: String
    let basePath: String

    init?(_ address: String) {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              (1...65535).contains(parts.port ?? 443) else { return nil }
        let path = parts.percentEncodedPath
        guard path.isEmpty || path == "/" ||
            path.range(of: #"^(/[A-Za-z0-9_-]+)+/?$"#, options: .regularExpression) != nil else { return nil }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        parts.path = ""
        guard let origin = parts.string else { return nil }
        let basePath = path.isEmpty ? "/" : path.hasSuffix("/") ? path : path + "/"
        parts.path = basePath
        guard let url = parts.url else { return nil }
        self.url = url
        self.origin = origin
        self.basePath = basePath
    }

    func contains(_ candidate: URL?) -> Bool {
        guard let candidate, candidate.user == nil, candidate.password == nil else { return false }
        guard candidate.scheme?.lowercased() == "https",
              candidate.host?.lowercased() == url.host?.lowercased(),
              (candidate.port ?? 443) == (url.port ?? 443) else { return false }
        guard basePath != "/" else { return true }
        guard let encodedPath = URLComponents(url: candidate, resolvingAgainstBaseURL: true)?.percentEncodedPath,
              !encodedPath.lowercased().contains("%2f"),
              let path = encodedPath.removingPercentEncoding,
              !path.contains("\\"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return path.hasPrefix(basePath) || path == String(basePath.dropLast())
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

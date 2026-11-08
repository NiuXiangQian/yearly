import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}

let site = SiteOrigin("  HTTPS://Family.Example.com:443/\n")!
check(site.url.absoluteString == "https://family.example.com/", "Normalize scheme, host, default port and whitespace")
for address in ["", "http://family.example.com", "javascript:alert(1)", "file:///etc/passwd", "https://",
                "https://user:password@family.example.com", "https://family.example.com/../login",
                "https://family.example.com?x=1", "https://family.example.com/#/login", "https://family.example.com:0",
                "https://family.example.com:65536"] {
    check(SiteOrigin(address) == nil, "Reject invalid site: \(address)")
}
for address in ["https://family.example.com/login", "https://FAMILY.EXAMPLE.COM/api/auth/me", "https://family.example.com:443/share/token"] {
    check(site.contains(URL(string: address)), "Allow same origin: \(address)")
}
for address in ["http://family.example.com/", "https://family.example.com.evil.test", "https://other.example.com",
                "https://family.example.com:8443/", "https://user@family.example.com", "https://family.example.com@evil.test",
                "file:///private/var", "data:text/html,hello", "about:blank", "blob:https://family.example.com/123"] {
    check(!site.contains(URL(string: address)), "Block cross-origin bridge: \(address)")
}
check(!site.contains(nil), "Reject missing URL")
let custom = SiteOrigin("https://family.example.com:8443")!
check(custom.contains(URL(string: "https://family.example.com:8443/upload")), "Allow configured custom port")
check(!custom.contains(URL(string: "https://family.example.com/upload")), "Do not conflate ports")
let prefixed = SiteOrigin("https://family.example.com/yearly")!
check(prefixed.url.absoluteString == "https://family.example.com/yearly/", "Normalize installation URL")
check(prefixed.origin == "https://family.example.com", "Origin header excludes installation path")
check(prefixed.contains(URL(string: "https://family.example.com/yearly/api/uploads")), "Allow prefixed API")
for path in ["/", "/login", "/yearly-other", "/yearly/%2e%2e/login", "/yearly%2fapi/uploads"] {
    check(!prefixed.contains(URL(string: prefixed.origin + path)), "Block URLs outside the installation path")
}
check(AppConfiguration.httpsURL("https://example.com/legal/privacy") != nil, "Policy pages allow paths")
for value in ["", "$(YEARLY_PRIVACY_URL)", "http://example.com", "https://user@host.test", "javascript:alert(1)"] {
    check(AppConfiguration.httpsURL(value) == nil, "Reject invalid release link")
}
check(SiteOrigin.isAttachmentURL(URL(string: "https://bucket.example.com/photo?response-content-disposition=attachment%3B%20filename%3Dphoto.heic")!), "Recognize OSS attachment")
for value in ["https://example.com/page", "https://example.com/?response-content-disposition=inline", "http://example.com/?response-content-disposition=attachment"] {
    check(!SiteOrigin.isAttachmentURL(URL(string: value)!), "Do not download ordinary or insecure links")
}
print("Passed \(checks) iOS origin/configuration/download policy checks.")

import Foundation

private final class MemoryCredentials: SessionCredentialStore {
    var values: [String: SessionCredential] = [:]
    func read(site: String) throws -> SessionCredential? { values[site] }
    func write(_ credential: SessionCredential?, site: String) throws { values[site] = credential }
}
private final class SessionHTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var role = "member"
    static var authorized = true
    static var secureCookie = true
    static var timelineFails = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = "{}"
        switch request.url!.path {
        case "/yearly/api/auth/captcha": body = "{\"id\":\"synthetic-captcha\",\"image\":\"data:image/png;base64,aGVsbG8=\"}"
        case "/yearly/api/auth/login":
            body = "{\"id\":1,\"role\":\"\(Self.role)\",\"username\":\"synthetic\",\"csrf_token\":\"test-csrf\"}"
            headers["Set-Cookie"] = "yearly_session=test-native-session; Max-Age=3600; Path=/yearly/; HttpOnly; SameSite=Strict" + (Self.secureCookie ? "; Secure" : "")
        case "/yearly/api/auth/me":
            status = Self.authorized ? 200 : 401
            body = "{\"id\":1,\"role\":\"\(Self.role)\",\"username\":\"synthetic\",\"csrf_token\":\"test-csrf\"}"
        case "/yearly/api/children": body = "[]"
        case "/yearly/api/timeline":
            if Self.timelineFails { status = 503; body = "{}"; break }
            let more = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
            body = more ? #"{"items":[{"id":7,"kind":"media","media_type":"live_photo"},{"id":8,"kind":"media","media_type":"video"}],"total":3,"next_cursor":null}"# : #"{"items":[{"id":7,"kind":"media","media_type":"live_photo","timeline_day":"2026-11-08","child_ids":[1,2],"files":[{"id":10,"file_role":"original","original_filename":"test.heic","mime_type":"image/heic","file_size":8},{"id":11,"file_role":"live_video","original_filename":"test.mov","mime_type":"video/quicktime","file_size":9}]},{"id":7,"kind":"event","content":"synthetic diary"}],"total":3,"next_cursor":"next+cursor/=="}"#
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct NativeSessionTests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionHTTP.self]
        config.httpCookieStorage = nil
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let site = SiteOrigin("https://native.invalid/yearly/")!
        let store = MemoryCredentials()
        let session = NativeSession(site: site, store: store, transport: transport)
        await session.restore()
        precondition(!session.restoring && session.account == nil)
        let captcha = try await session.captcha()
        precondition(captcha.png == Data("hello".utf8))
        try await session.login(username: "synthetic", password: "not-saved-password", captcha: captcha, answer: "ABCDE")
        precondition(session.account?.id == 1 && session.canEdit)
        precondition(store.values.count == 1 && store.values[site.url.absoluteString]?.value == "test-native-session")
        precondition(session.cookies().first?.path == "/yearly/" && session.cookies().first?.isSecure == true)
        let login = SessionHTTP.requests.first { $0.url?.path.hasSuffix("/auth/login") == true }!
        precondition(login.value(forHTTPHeaderField: "Origin") == "https://native.invalid")
        precondition(login.value(forHTTPHeaderField: "Cookie") == nil)
        try await session.write("/media/42", json: ["child_ids": [1, 2]])
        let write = SessionHTTP.requests.last!
        precondition(write.httpMethod == "PUT")
        precondition(write.value(forHTTPHeaderField: "X-CSRF-Token") == "test-csrf")
        precondition(write.value(forHTTPHeaderField: "Cookie") == "yearly_session=test-native-session")
        let timeline = NativeTimelineStore(session: session)
        timeline.selected = [1, 2]
        await timeline.load()
        precondition(timeline.items.count == 2 && !timeline.loading && timeline.total == 3)
        precondition(timeline.items[0].primary?.id == 10 && timeline.items[0].motion?.id == 11)
        precondition(timeline.items[0].stableID != timeline.items[1].stableID)
        let filterQuery = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(filterQuery.filter { $0.name == "child_id" }.compactMap(\.value) == ["1", "2"])
        await timeline.load(more: true)
        precondition(timeline.items.count == 3 && timeline.cursor == nil && !timeline.loading)
        let cursorQuery = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(cursorQuery.first { $0.name == "cursor" }?.value == "next+cursor/==")
        SessionHTTP.timelineFails = true
        await timeline.load()
        precondition(timeline.items.count == 3 && !timeline.error.isEmpty && !timeline.loading)
        SessionHTTP.timelineFails = false
        let restored = NativeSession(site: site, store: store, transport: transport)
        await restored.restore()
        precondition(restored.account?.id == 1)
        let otherSite = NativeSession(site: SiteOrigin("https://native.invalid/other/")!, store: store, transport: transport)
        await otherSite.restore()
        precondition(otherSite.account == nil && otherSite.cookies().isEmpty)
        try await restored.logout()
        precondition(restored.cookies().isEmpty && restored.account == nil && store.values.isEmpty)
        let logout = SessionHTTP.requests.last!
        precondition(logout.value(forHTTPHeaderField: "Origin") == "https://native.invalid")
        precondition(logout.value(forHTTPHeaderField: "X-CSRF-Token") == "test-csrf")
        SessionHTTP.role = "viewer"
        try await session.login(username: "synthetic", password: "not-saved-password", captcha: captcha, answer: "ABCDE")
        precondition(!session.canEdit)
        let count = SessionHTTP.requests.count
        do { try await session.write("/media/42", json: [:]); fatalError("viewer cannot write") }
        catch { precondition(SessionHTTP.requests.count == count) }
        SessionHTTP.authorized = false
        let expired = NativeSession(site: site, store: store, transport: transport)
        await expired.restore()
        precondition(expired.account == nil && store.values.isEmpty)
        SessionHTTP.secureCookie = false
        do { try await expired.login(username: "synthetic", password: "not-saved-password", captcha: captcha, answer: "ABCDE"); fatalError("insecure cookie accepted") }
        catch { precondition(expired.account == nil && store.values.isEmpty) }
        print("Native session mocks passed: captcha, login, Keychain boundary, app-path isolation, CSRF, role, expiry, logout, native timeline Live Photo decoding/filter/pagination/retry, HTTPS Cookie requirements; no live network.")
    }
}

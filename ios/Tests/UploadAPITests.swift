import Foundation

// Intercepts every URL; these tests cannot send any request to an actual server.
private final class MockHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var role = "member"
    static var authenticated = true
    static var capable = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let role = Self.role, authenticated = Self.authenticated, capable = Self.capable
        Self.lock.unlock()
        var status = 200, headers = ["Content-Type": "application/json"], body = "{}"
        switch request.url!.path {
        case "/yearly/api/auth/me":
            status = authenticated ? 200 : 401
            body = "{\"id\":1,\"role\":\"\(role)\",\"csrf_token\":\"synthetic-csrf\"}"
        case "/yearly/api/uploads":
            if request.httpMethod == "GET" {
                body = "[]"
                if capable { headers["X-Yearly-Upload-Protocol"] = "idempotent-v1" }
            } else { body = "{\"media_id\":42,\"duplicate\":true,\"tasks\":[]}" }
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
    static func reset(role: String = "member", authenticated: Bool = true, capable: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        requests = []; self.role = role; self.authenticated = authenticated; self.capable = capable
    }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

@main struct UploadAPITests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let site = SiteOrigin("https://yearly.invalid/yearly")!
        let cookie = HTTPCookie(properties: [.name: "yearly_session", .value: "synthetic-session", .domain: "yearly.invalid", .path: "/yearly/", .secure: "TRUE"])!
        let wrong = HTTPCookie(properties: [.name: "yearly_session", .value: "wrong-site-session", .domain: "elsewhere.invalid", .path: "/yearly/", .secure: "TRUE"])!
        let rootCookie = HTTPCookie(properties: [.name: "yearly_session", .value: "root-session", .domain: "yearly.invalid", .path: "/", .secure: "TRUE"])!
        let api = UploadAPI(site: site, ownerID: 1, cookieProvider: { [wrong, rootCookie, cookie] }, session: session)
        let key = UUID()
        let result = try await api.create(body: Data("{}".utf8), key: key)
        precondition(result.duplicate == true && result.media_id == 42)
        let requests = MockHTTP.captured()
        precondition(requests.map { $0.url!.path } == ["/yearly/api/auth/me", "/yearly/api/uploads", "/yearly/api/uploads"])
        let create = requests.last!
        precondition(create.value(forHTTPHeaderField: "Cookie") == "yearly_session=synthetic-session")
        precondition(create.value(forHTTPHeaderField: "Origin") == "https://yearly.invalid")
        precondition(create.value(forHTTPHeaderField: "X-CSRF-Token") == "synthetic-csrf")
        precondition(create.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString.lowercased())
        try await api.put(Data("synthetic-original".utf8), to: URL(string: "https://oss.invalid/part")!)
        let put = MockHTTP.captured().last!
        precondition(put.httpMethod == "PUT")
        for header in ["Cookie", "Origin", "Authorization", "X-CSRF-Token", "Idempotency-Key"] {
            precondition(put.value(forHTTPHeaderField: header) == nil)
        }
        for (role, authenticated, capable) in [("viewer", true, true), ("member", false, true), ("member", true, false)] {
            MockHTTP.reset(role: role, authenticated: authenticated, capable: capable)
            do { _ = try await api.create(body: Data("{}".utf8), key: key); fatalError("Must reject before create") }
            catch { precondition(!MockHTTP.captured().contains { $0.httpMethod == "POST" }) }
        }
        MockHTTP.reset()
        let switched = UploadAPI(site: site, ownerID: 2, cookieProvider: { [cookie] }, session: session)
        do { _ = try await switched.create(body: Data("{}".utf8), key: key); fatalError("Must reject changed account") }
        catch { precondition(MockHTTP.captured().count == 1) }
        MockHTTP.reset()
        let noCookie = UploadAPI(site: site, ownerID: 1, cookieProvider: { [wrong] }, session: session)
        do { _ = try await noCookie.create(body: Data("{}".utf8), key: key); fatalError("Must reject wrong-origin cookie") }
        catch { precondition(MockHTTP.captured().isEmpty) }
        print("Passed native HTTP mock checks: Cookie/CSRF/Origin, OSS credential isolation, role/session/account checks, old-server preflight.")
    }
}

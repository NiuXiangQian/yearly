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
    static var shareRevoked = false
    static var sharesFail = false
    static var lastShareBody: [String: Any] = [:]
    static var ignoreSelection = false
    static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
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
        case "/yearly/api/media/42": body = #"{"id":42,"media_type":"live_photo","timeline_day":"2018-01-03"}"#
        case "/yearly/api/media/43": body = #"{"id":43,"media_type":"video"}"#
        case "/yearly/api/media/44": status = 404
        case "/yearly/api/shares", "/yearly/api/shares/42":
            if Self.sharesFail { status = 503; break }
            if request.httpMethod == "DELETE" { Self.shareRevoked = true; break }
            if request.httpMethod == "POST" {
                Self.shareRevoked = false
                Self.lastShareBody = (try? JSONSerialization.jsonObject(with: Self.bodyData(request))) as? [String: Any] ?? [:]
            }
            let selected = Self.ignoreSelection ? nil : Self.lastShareBody["media_ids"] as? [Int]
            let scope = selected == nil ? "date_range" : "selection"
            let scopeJSON = ",\"scope\":\"\(scope)\",\"selected_count\":\(selected.map { String(Set($0).count) } ?? "null")"
            let record = "{\"id\":42,\"title\":\"synthetic share\",\"start_date\":\"2026-11-08\",\"end_date\":\"2026-11-09\",\"expires_at\":\"2099-01-01T12:00:00.123456Z\",\"revoked\":\(Self.shareRevoked),\"expired\":false"
            body = request.httpMethod == "POST" ? record + scopeJSON + ",\"token\":\"synthetic_share_token\"}" : "[" + record + "}]"
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
        let loadedRequestCount = SessionHTTP.requests.count
        await timeline.loadIfNeeded()
        precondition(SessionHTTP.requests.count == loadedRequestCount, "tab switching reuses loaded timeline")
        let filterQuery = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(filterQuery.filter { $0.name == "child_id" }.compactMap(\.value) == ["1", "2"])
        await timeline.load(more: true)
        precondition(timeline.items.count == 3 && timeline.cursor == nil && !timeline.loading)
        let cursorQuery = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(cursorQuery.first { $0.name == "cursor" }?.value == "next+cursor/==")
        let beforeReset = SessionHTTP.requests.count
        timeline.resetForAccountChange()
        precondition(timeline.items.isEmpty && timeline.profiles.isEmpty && timeline.cursor == nil && timeline.total == 0)
        await timeline.loadIfNeeded()
        precondition(SessionHTTP.requests.count > beforeReset && timeline.items.count == 2, "account change invalidates the cached query")
        await timeline.load(more: true)
        SessionHTTP.timelineFails = true
        await timeline.load()
        precondition(timeline.items.count == 3 && !timeline.error.isEmpty && !timeline.loading)
        SessionHTTP.timelineFails = false
        await timeline.load()
        precondition(timeline.cursor != nil)
        let previousRequestCount = SessionHTTP.requests.count
        timeline.search = "旅途 & 家人"
        await timeline.load(more: true)
        precondition(SessionHTTP.requests.count == previousRequestCount, "changed filters must not reuse a previous cursor")
        timeline.mediaType = "live_photo"
        timeline.ascending = true
        timeline.useDateRange = true
        timeline.startDate = NativeDay.date("2026-11-08")!
        timeline.endDate = NativeDay.date("2026-11-09")!
        await timeline.load()
        let filters = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(filters.first { $0.name == "q" }?.value == "旅途 & 家人")
        precondition(filters.first { $0.name == "media_type" }?.value == "live_photo")
        precondition(filters.first { $0.name == "order" }?.value == "asc")
        precondition(filters.first { $0.name == "start" }?.value == "2026-11-08T00:00:00")
        precondition(filters.first { $0.name == "end" }?.value == "2026-11-10T00:00:00")
        precondition(!filters.contains { $0.name == "cursor" })
        precondition(NativeDay.date("2026-02-30") == nil)
        precondition(NativeDay.following(NativeDay.date("2024-02-28")!) == "2024-02-29")
        timeline.resetFilters()
        precondition(!timeline.hasFilters)
        let reorderPair = try JSONDecoder().decode([NativeTimelineItem].self, from: Data(
            #"[{"id":10,"kind":"media","timeline_day":"2026-11-08"},{"id":11,"kind":"media","timeline_day":"2026-11-08"}]"#.utf8
        ))
        timeline.items = reorderPair
        var otherDay = reorderPair[1]
        otherDay.timeline_day = "2026-11-09"
        let beforeReorder = SessionHTTP.requests.count
        await timeline.reorder(reorderPair[0], relativeTo: otherDay)
        precondition(SessionHTTP.requests.count == beforeReorder, "dragging across days must not change archive dates")
        await timeline.reorder(reorderPair[0], relativeTo: reorderPair[1])
        let reorder = SessionHTTP.requests[beforeReorder]
        let reorderBody = try JSONSerialization.jsonObject(with: SessionHTTP.bodyData(reorder)) as? [String: Any]
        precondition(reorder.url?.path.hasSuffix("/media/reorder") == true && reorder.httpMethod == "POST")
        precondition(reorderBody?["target_id"] as? Int == 11 && reorderBody?["placement"] as? String == "after")
        timeline.search = "原来的筛选"
        let beforeUploadReview = SessionHTTP.requests.count
        timeline.focusOnUploads([43, 42, 42, 44])
        await timeline.loadIfNeeded()
        precondition(SessionHTTP.requests.dropFirst(beforeUploadReview).map { $0.url!.path } ==
                     ["/yearly/api/media/42", "/yearly/api/media/43", "/yearly/api/media/44"])
        precondition(timeline.items.map(\.stableID) == ["media-42", "media-43"] && timeline.cursor == nil)
        precondition(timeline.items.map(\.day) == ["2018-01-03", "日期未知"])
        timeline.focusOnUploads([])
        precondition(!timeline.showingUploads && timeline.search == "原来的筛选")
        timeline.showDay("2018-01-03")
        await timeline.loadIfNeeded()
        let dayParams = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(dayParams.first { $0.name == "start" }?.value == "2018-01-03T00:00:00")
        precondition(dayParams.first { $0.name == "end" }?.value == "2018-01-04T00:00:00")
        let sharing = NativeSharingStore(session: session)
        await sharing.load()
        precondition(sharing.shares.count == 1 && sharing.shares[0].token == nil)
        precondition(sharing.shares[0].link(site: site) == nil)
        let startDate = NativeDay.date("2026-11-08")!, endDate = NativeDay.date("2026-11-09")!
        let beforeInvalid = SessionHTTP.requests.count
        await sharing.create(title: "Invalid", start: endDate, end: startDate, hours: 24)
        precondition(SessionHTTP.requests.count == beforeInvalid && sharing.created == nil)
        await sharing.create(title: "Invalid", start: startDate, end: endDate, hours: 169)
        precondition(SessionHTTP.requests.count == beforeInvalid)
        await sharing.create(title: "Family", start: startDate, end: endDate, hours: 24)
        precondition(sharing.created?.link(site: site)?.absoluteString == "https://native.invalid/yearly/share/synthetic_share_token")
        let createShare = SessionHTTP.requests.last!
        precondition(createShare.httpMethod == "POST" && createShare.value(forHTTPHeaderField: "X-CSRF-Token") == "test-csrf")
        precondition(createShare.value(forHTTPHeaderField: "Origin") == "https://native.invalid")
        SessionHTTP.sharesFail = true
        await sharing.load()
        precondition(!sharing.error.isEmpty && !sharing.busy && !sharing.shares.isEmpty)
        SessionHTTP.sharesFail = false
        await sharing.revoke(sharing.created!)
        precondition(sharing.created?.link(site: site) == nil && sharing.created?.revoked == true)
        precondition(SessionHTTP.requests.last?.httpMethod == "DELETE")
        let selection = NativeSharingStore(session: session)
        let beforeEmpty = SessionHTTP.requests.count
        await selection.create(title: "Empty", start: startDate, end: endDate, hours: 24, mediaIDs: [])
        precondition(SessionHTTP.requests.count == beforeEmpty && selection.created == nil)
        await selection.create(title: "Selected", start: endDate, end: startDate, hours: 24, mediaIDs: [7, 8])
        precondition(selection.created?.scope == "selection" && selection.created?.selected_count == 2)
        precondition(SessionHTTP.lastShareBody["media_ids"] as? [Int] == [7, 8])
        precondition(SessionHTTP.lastShareBody["start_date"] == nil && SessionHTTP.lastShareBody["end_date"] == nil)
        SessionHTTP.ignoreSelection = true
        let incompatible = NativeSharingStore(session: session)
        await incompatible.create(title: "Must not broaden", start: startDate, end: endDate, hours: 24, mediaIDs: [7])
        precondition(incompatible.created == nil && !incompatible.error.isEmpty && SessionHTTP.shareRevoked)
        SessionHTTP.ignoreSelection = false
        let unsafe = try JSONDecoder().decode(NativeShare.self, from: Data(#"{"id":1,"title":"","start_date":"2026-11-08","end_date":"2026-11-09","expires_at":"2099-01-01T00:00:00Z","expired":false,"revoked":false,"token":"../../outside?secret"}"#.utf8))
        precondition(unsafe.link(site: site) == nil)
        let expiredLink = try JSONDecoder().decode(NativeShare.self, from: Data(#"{"id":1,"title":"","start_date":"2026-11-08","end_date":"2026-11-09","expires_at":"2020-01-01T00:00:00Z","expired":false,"revoked":false,"token":"synthetic_expired"}"#.utf8))
        precondition(expiredLink.link(site: site) == nil && !expiredLink.usable)
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
        let readOnlySharing = NativeSharingStore(session: session)
        let beforeShare = SessionHTTP.requests.count
        await readOnlySharing.create(title: "Denied", start: startDate, end: endDate, hours: 24)
        precondition(SessionHTTP.requests.count == beforeShare && readOnlySharing.created == nil && !readOnlySharing.error.isEmpty)
        SessionHTTP.authorized = false
        let expired = NativeSession(site: site, store: store, transport: transport)
        await expired.restore()
        precondition(expired.account == nil && store.values.isEmpty)
        SessionHTTP.secureCookie = false
        do { try await expired.login(username: "synthetic", password: "not-saved-password", captcha: captcha, answer: "ABCDE"); fatalError("insecure cookie accepted") }
        catch { precondition(expired.account == nil && store.values.isEmpty) }
        print("Native session mocks passed: captcha, login, Keychain boundary, app-path isolation, CSRF, role, expiry, logout, native timeline search/date/type/order, share create/revoke/scope/role/expiry, HTTPS Cookie requirements; no live network.")
    }
}

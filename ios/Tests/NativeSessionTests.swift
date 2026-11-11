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
    static var usersFail = false
    static var uploadersEmpty = false
    static var writeFailure: String?
    static var nickname = ""
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
            body = "{\"id\":1,\"role\":\"\(Self.role)\",\"username\":\"synthetic\",\"nickname\":\"\(Self.nickname)\",\"csrf_token\":\"test-csrf\"}"
            headers["Set-Cookie"] = "yearly_session=test-native-session; Max-Age=3600; Path=/yearly/; HttpOnly; SameSite=Strict" + (Self.secureCookie ? "; Secure" : "")
        case "/yearly/api/auth/me":
            status = Self.authorized ? 200 : 401
            body = "{\"id\":1,\"role\":\"\(Self.role)\",\"username\":\"synthetic\",\"nickname\":\"\(Self.nickname)\",\"csrf_token\":\"test-csrf\"}"
        case "/yearly/api/uploaders": body = Self.uploadersEmpty ? "[]" : "[{\"id\":1,\"username\":\"synthetic\",\"nickname\":\"\(Self.nickname)\"},{\"id\":2,\"username\":\"other\",\"nickname\":\"明月\"}]"
        case "/yearly/api/users":
            if Self.usersFail { status = 503; body = #"{"detail":"Synthetic failure"}"# }
            else { body = request.httpMethod == "POST" ? #"{"id":3}"# : #"[{"id":1,"username":"synthetic","role":"admin","active":true},{"id":2,"username":"other","role":"member","active":false}]"# }
        case "/yearly/api/users/1", "/yearly/api/users/2": body = #"{"ok":true}"#
        case "/yearly/api/audit-logs": body = #"{"items":[{"id":1,"actor_name":"synthetic","resource_type":"media","resource_id":"42","action":"update","created_at":"2026-11-09T07:00:00.123","changes":{"title":{"before":"old","after":"new"},"password":{"changed":true},"tags":{"before":[],"after":["family"]}}}],"total":1}"#
        case "/yearly/api/children": body = "[]"
        case "/yearly/api/children/1":
            body = #"{"id":1,"name":"家庭成员","nickname":"新昵称","profile_type":"person","birthday":"2020-01-03","avatar_media_id":42,"status":"archived"}"#
        case "/yearly/api/media/42": body = #"{"id":42,"media_type":"live_photo","timeline_day":"2018-01-03"}"#
        case "/yearly/api/media/43": body = #"{"id":43,"media_type":"video"}"#
        case "/yearly/api/media/44": status = 404
        case "/yearly/api/shares/42/link": body = #"{"token":"saved_share_token"}"#
        case "/yearly/api/shares/42/copy":
            body = #"{"id":43,"title":"synthetic share","start_date":"2026-11-08","end_date":"2026-11-09","expires_at":"2099-01-01T12:00:00Z","revoked":false,"expired":false,"token":"copy_share_token","link_available":true,"can_copy":true}"#
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
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let more = params.contains { $0.name == "cursor" }
            if params.contains(URLQueryItem(name: "anchor_day", value: "2020-01-03")) {
                body = params.contains(URLQueryItem(name: "before", value: "true"))
                    ? #"{"items":[{"id":6,"kind":"media","timeline_day":"2020-01-04"}],"total":3}"#
                    : #"{"items":[{"id":5,"kind":"media","timeline_day":"2020-01-03"}],"total":3,"next_cursor":"day+cursor/=="}"#
                break
            }
            if params.contains(URLQueryItem(name: "anchor_media_id", value: "42")) {
                if params.contains(URLQueryItem(name: "before", value: "true")) {
                    body = more
                        ? #"{"items":[{"id":40,"kind":"media"}],"total":4,"previous_cursor":null}"#
                        : #"{"items":[{"id":41,"kind":"media"}],"total":4,"previous_cursor":"newer+cursor/=="}"#
                } else {
                    body = more
                        ? #"{"items":[{"id":43,"kind":"media"}],"total":4,"next_cursor":null}"#
                        : #"{"items":[{"id":42,"kind":"media"}],"total":4,"next_cursor":"older+cursor/=="}"#
                }
                break
            }
            body = more ? #"{"items":[{"id":7,"kind":"media","media_type":"live_photo"},{"id":8,"kind":"media","media_type":"video","timeline_day":"2026-11-07"}],"total":3,"next_cursor":null}"# : #"{"items":[{"id":7,"kind":"media","media_type":"live_photo","timeline_day":"2026-11-08","media_position":{"index":1,"total":2,"day_index":1,"day_total":1},"child_ids":[1,2],"files":[{"id":10,"file_role":"original","original_filename":"test.heic","mime_type":"image/heic","file_size":8},{"id":11,"file_role":"live_video","original_filename":"test.mov","mime_type":"video/quicktime","file_size":9}]},{"id":7,"kind":"event","content":"synthetic diary"}],"total":3,"next_cursor":"next+cursor/=="}"#
        default: break
        }
        if request.url?.path == "/yearly/api/users/1", request.httpMethod == "PUT",
           let payload = try? JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any],
           let nickname = payload["nickname"] as? String { Self.nickname = nickname }
        if request.httpMethod != "GET", let failure = Self.writeFailure { status = 422; body = failure }
        if request.url!.path == "/yearly/api/timeline", status == 200,
           request.url!.query?.contains("include_dates=true") == true {
            body.removeLast()
            body += #", "dates":["2020-01-03","2026-11-07","2026-11-08"]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct NativeSessionTests {
    @MainActor static func main() async throws {
        for value in ["", "a", "has space", "invalid!", String(repeating: "a", count: 81)] {
            precondition(NativeAccountValidation.username(value) != nil)
        }
        for value in ["家人", "user.name@home-1", String(repeating: "a", count: 80)] {
            precondition(NativeAccountValidation.username(value) == nil)
        }
        for count in [0, 11, 257] { precondition(NativeAccountValidation.password(String(repeating: "a", count: count)) != nil) }
        for count in [12, 256] { precondition(NativeAccountValidation.password(String(repeating: "a", count: count)) == nil) }
        precondition(NativeAccountValidation.password("", optional: true) == nil)
        precondition(NativeAccountValidation.password("short", optional: true) != nil)
        precondition(NativeAccountValidation.password(String(repeating: "👩🏽", count: 6)) == nil, "length matches the API's Unicode code point count")
        let passwordFailure = #"{"detail":[{"type":"string_too_short","loc":["body","new_password"],"msg":"String should have at least 12 characters","input":"private-input-must-not-appear","ctx":{"min_length":12}}]}"#
        precondition(nativeResponseDetail(Data(passwordFailure.utf8)) == "新密码至少需要 12 个字符。")
        precondition(nativeResponseDetail(Data(#"{"detail":"当前密码不正确"}"#.utf8)) == "当前密码不正确")
        precondition(nativeResponseDetail(Data(#"{"detail":[{"type":"string_too_long","loc":["body","title"],"ctx":{"max_length":255}},{"type":"less_than_equal","loc":["body","latitude"],"ctx":{"le":90}}]}"#.utf8)) == "标题最多允许 255 个字符。\n纬度不能大于 90。")
        precondition(nativeResponseDetail(Data(#"{"detail":[{"type":"string_pattern_mismatch","loc":["body","username"]}]}"#.utf8))?.contains("用户名只能包含") == true)
        precondition(nativeResponseDetail(Data(#"{"detail":[{"type":"unknown","loc":["body","password"],"input":"private-input-must-not-appear"}]}"#.utf8)) == "密码不符合要求，请检查后重试。")
        precondition(nativeResponseDetail(Data("not json".utf8)) == nil)
        precondition(nativeResponseDetail(Data(#"{"detail":[]}"#.utf8)) == nil)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("YearlyCacheTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let disk = NativeLocalCache(directory: cacheDirectory)
        disk.insert(Data("[]".utf8), scope: "site-a|1", key: "page", category: "lists", lifetime: 300)
        let reopened = NativeLocalCache(directory: cacheDirectory)
        precondition(reopened.data(scope: "site-a|1", key: "page", category: "lists") == Data("[]".utf8), "empty results persist across cache instances")
        precondition(reopened.data(scope: "site-a|2", key: "page", category: "lists") == nil)
        precondition(reopened.data(scope: "site-b|1", key: "page", category: "lists") == nil)
        disk.insert(Data("expired".utf8), scope: "site-a|1", key: "old", category: "lists", lifetime: -1)
        precondition(reopened.data(scope: "site-a|1", key: "old", category: "lists") == nil)
        disk.clear(scope: "site-a|1")
        precondition(reopened.data(scope: "site-a|1", key: "page", category: "lists") == nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionHTTP.self]
        config.httpCookieStorage = nil
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let site = SiteOrigin("https://native.invalid/yearly/")!
        let store = MemoryCredentials()
        let session = NativeSession(site: site, store: store, transport: transport, cacheDirectory: cacheDirectory)
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
        let calendarScale = NativeTimelineScale(days: ["2026-11-09", "2026-11-08", "2026-10-10"])
        precondition(calendarScale.ratio(for: "2026-11-09") == 0)
        precondition(calendarScale.ratio(for: "2026-10-10") == 1)
        precondition(abs(calendarScale.ratio(for: "2026-11-08") - 1.0 / 30) < 0.000001)
        precondition(calendarScale.nearest(to: 0.5) == "2026-11-08", "calendar gaps keep their elapsed-time span")
        precondition(calendarScale.nearest(to: -1) == "2026-11-09" && calendarScale.nearest(to: 2) == "2026-10-10")
        precondition(calendarScale.markers(height: 440) == ["2026-11-09", "2026-10-10"], "nearby dates stay reachable without overlapping markers")
        let ascendingScale = NativeTimelineScale(days: Array(calendarScale.days.reversed()))
        precondition(ascendingScale.ratio(for: "2026-10-10") == 0 && ascendingScale.ratio(for: "2026-11-09") == 1)
        precondition(ascendingScale.nearest(to: 0.98) == "2026-11-08")
        let dailyDates = (1...30).map { String(format: "2026-10-%02d", $0) }
        let dailyScale = NativeTimelineScale(days: dailyDates)
        precondition(dailyScale.markers(height: 440).count <= 11)
        precondition(dailyScale.markers(height: 176).count < dailyScale.markers(height: 440).count)
        precondition(dailyScale.markers(height: 440).first == dailyDates.first && dailyScale.markers(height: 440).last == dailyDates.last)
        precondition(dailyScale.nearest(to: dailyScale.ratio(for: "2026-10-15")) == "2026-10-15", "dragging reaches dates between visible markers")
        let oneDayScale = NativeTimelineScale(days: ["2026-11-09"])
        precondition(oneDayScale.markers(height: 440) == ["2026-11-09"] && oneDayScale.nearest(to: 1) == "2026-11-09")
        precondition(NativeTimelineScale(days: []).nearest(to: 0) == nil)
        precondition(NativeTimelineScale(days: ["日期未知"]).days.isEmpty)
        let timeline = NativeTimelineStore(session: session)
        let beforeDeniedDay = SessionHTTP.requests.count
        do { try await timeline.setDaySharing("2026-11-08", allowed: false); fatalError("member changed global day permissions") }
        catch { precondition(SessionHTTP.requests.count == beforeDeniedDay) }
        SessionHTTP.role = "admin"
        await session.restore()
        try await timeline.setDaySharing("2026-11-08", allowed: false)
        precondition(timeline.daySharing["2026-11-08"] == false)
        let dayUpdate = SessionHTTP.requests.last!
        precondition(dayUpdate.httpMethod == "PUT" && dayUpdate.url?.path == "/yearly/api/timeline/days/2026-11-08/sharing")
        let dayPayload = try JSONSerialization.jsonObject(with: SessionHTTP.bodyData(dayUpdate)) as? [String: Bool]
        precondition(dayPayload == ["share_allowed": false])
        SessionHTTP.role = "member"
        await session.restore()
        timeline.selected = [1, 2]
        await timeline.load()
        precondition(timeline.items.count == 2 && !timeline.loading && timeline.total == 3)
        precondition(timeline.items[0].primary?.id == 10 && timeline.items[0].motion?.id == 11)
        precondition(timeline.items[0].media_position?.total == 2 && timeline.items[0].media_position?.day_total == 1)
        precondition(timeline.items[0].stableID != timeline.items[1].stableID)
        let firstLoadCount = SessionHTTP.requests.count
        let reopenedTimeline = NativeTimelineStore(session: session)
        reopenedTimeline.selected = [1, 2]
        await reopenedTimeline.load()
        precondition(SessionHTTP.requests.count == firstLoadCount && reopenedTimeline.items.count == 2, "recreating the list reuses persisted pages")
        try await session.write("/media/42", json: ["title": "updated"])
        await timeline.load()
        precondition(SessionHTTP.requests.count == firstLoadCount + 2, "a successful write invalidates cached pages")
        let loadedRequestCount = SessionHTTP.requests.count
        await timeline.loadIfNeeded()
        precondition(SessionHTTP.requests.count == loadedRequestCount, "tab switching reuses loaded timeline")
        let filterQuery = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(filterQuery.filter { $0.name == "child_id" }.compactMap(\.value) == ["1", "2"])
        precondition(filterQuery.contains(URLQueryItem(name: "media_positions", value: "true")))
        await timeline.load(more: true)
        precondition(timeline.items.count == 3 && timeline.cursor == nil && !timeline.loading)
        precondition(timeline.mediaPages(timeline.items).map(\.day) == ["2026-11-08", "2026-11-07"])
        var afterDeletion = NativeMediaPosition(index: 4, total: 5, day_index: 3, day_total: 4)
        afterDeletion.remove(NativeMediaPosition(index: 3, total: 5, day_index: 2, day_total: 4), sameDay: true)
        precondition(afterDeletion.index == 3 && afterDeletion.total == 4 && afterDeletion.day_index == 2 && afterDeletion.day_total == 3)
        let cursorQuery = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(cursorQuery.first { $0.name == "cursor" }?.value == "next+cursor/==")
        let beforeReset = SessionHTTP.requests.count
        timeline.resetForAccountChange()
        precondition(timeline.items.isEmpty && timeline.profiles.isEmpty && timeline.cursor == nil && timeline.total == 0)
        await timeline.loadIfNeeded()
        precondition(SessionHTTP.requests.count > beforeReset && timeline.items.count == 2, "resetting account filters requests their own cached query")
        await timeline.load(more: true)
        SessionHTTP.timelineFails = true
        await timeline.load(refresh: true)
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
        await timeline.load()
        precondition(timeline.railDays == ["2020-01-03", "2026-11-07", "2026-11-08"], "the rail includes dates outside the loaded page and follows ascending order")
        timeline.search = "旅途"
        timeline.mediaType = "photo"
        timeline.selected = [2]
        await timeline.loadIfNeeded()
        timeline.jump(to: "2020-01-03")
        await timeline.loadIfNeeded()
        precondition(timeline.anchorDay == "2020-01-03" && timeline.items.contains { $0.id == 5 })
        precondition(timeline.cursor == "day+cursor/==" && !timeline.hasNewer)
        let jumpParams = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(jumpParams.contains(URLQueryItem(name: "anchor_day", value: "2020-01-03")))
        precondition(jumpParams.contains(URLQueryItem(name: "before", value: "true")))
        precondition(jumpParams.contains(URLQueryItem(name: "q", value: "旅途")))
        precondition(jumpParams.contains(URLQueryItem(name: "media_type", value: "photo")))
        precondition(jumpParams.contains(URLQueryItem(name: "child_id", value: "2")))
        timeline.search = "另一个关键词"
        precondition(timeline.anchorDay == nil, "changing filters clears the date anchor")
        await timeline.loadIfNeeded()
        precondition(!timeline.archiveExpanded && !timeline.hasNewer)
        precondition(SessionHTTP.requests.last!.url!.query?.contains("anchor_day") == false)
        timeline.ascending = false
        precondition(timeline.railDays.first == "2026-11-08")
        timeline.resetFilters()
        let reorderPair = try JSONDecoder().decode([NativeTimelineItem].self, from: Data(
            #"[{"id":10,"kind":"media","owner_id":1,"can_edit":true,"timeline_day":"2026-11-08"},{"id":11,"kind":"media","owner_id":1,"can_edit":true,"timeline_day":"2026-11-08"}]"#.utf8
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
        timeline.showRecentUploads()
        await timeline.loadIfNeeded()
        let recentParams = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(recentParams.contains(URLQueryItem(name: "date_basis", value: "upload")))
        let uploaded = try JSONDecoder().decode(NativeTimelineItem.self, from: Data(
            #"{"id":42,"kind":"media","timeline_day":"2018-01-03","uploaded_at":"2026-11-08T23:30:00.123"}"#.utf8
        ))
        precondition(uploaded.uploadDate != nil && timeline.groupDay(uploaded) != uploaded.day)
        let uploadCount = try await timeline.uploadDayTotal(timeline.groupDay(uploaded))
        precondition(uploadCount == 3)
        let uploadCountParams = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(uploadCountParams.contains(URLQueryItem(name: "date_basis", value: "upload")))
        precondition(uploadCountParams.contains(URLQueryItem(name: "page_size", value: "1")))
        precondition(uploadCountParams.contains { $0.name == "start" } && uploadCountParams.contains { $0.name == "end" })
        timeline.locate(uploaded)
        await timeline.loadIfNeeded()
        let anchorParams = URLComponents(url: SessionHTTP.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(anchorParams.contains(URLQueryItem(name: "anchor_media_id", value: "42")))
        precondition(!anchorParams.contains { $0.name == "date_basis" } && timeline.groupDay(uploaded) == uploaded.day)
        await timeline.expandArchive()
        precondition(timeline.anchorMediaID == 42 && timeline.items.map(\.id) == [41, 42])
        precondition(timeline.hasNewer && timeline.cursor == "older+cursor/==")
        await timeline.load(more: true)
        await timeline.loadNewer()
        precondition(timeline.items.map(\.id) == [40, 41, 42, 43] && !timeline.hasNewer && timeline.cursor == nil)
        timeline.locate(uploaded, expandingArchive: true)
        await timeline.loadIfNeeded()
        precondition(timeline.archiveExpanded && timeline.items.map(\.id) == [41, 42], "relocating after deletion keeps the complete timeline expanded and reloads newer memories")
        timeline.focusOnUploads([])
        await timeline.loadIfNeeded()
        precondition(!timeline.isFocused && timeline.anchorMediaID == nil && timeline.items.contains { $0.id == 7 }, "leaving an unavailable archive returns to the complete timeline")
        let updatedProfile = try await session.updateProfile(id: 1, json: ["nickname": "新昵称"])
        precondition(updatedProfile.nickname == "新昵称" && updatedProfile.avatar_media_id == 42 && updatedProfile.status == "archived")
        precondition(SessionHTTP.requests.last?.httpMethod == "PUT")
        let sharing = NativeSharingStore(session: session)
        await sharing.load()
        precondition(sharing.shares.count == 1 && sharing.shares[0].token == nil)
        precondition(sharing.shares[0].link(site: site) == nil)
        let startDate = NativeDay.date("2026-11-08")!, endDate = NativeDay.date("2026-11-09")!
        let beforeInvalid = SessionHTTP.requests.count
        await sharing.create(title: "Invalid", start: endDate, end: startDate, hours: 24)
        precondition(SessionHTTP.requests.count == beforeInvalid && sharing.created == nil)
        await sharing.create(title: "Invalid", start: startDate, end: endDate, hours: 169)
        await sharing.create(title: String(repeating: "长", count: 121), start: startDate, end: endDate, hours: 24)
        precondition(SessionHTTP.requests.count == beforeInvalid && sharing.error == "分享标题最多 120 个字符。")
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
        await selection.create(title: "Selected", start: endDate, end: startDate, hours: 24, mediaIDs: [7, 8], profileID: 1)
        precondition(selection.created?.scope == "selection" && selection.created?.selected_count == 2)
        precondition(SessionHTTP.lastShareBody["media_ids"] as? [Int] == [7, 8])
        precondition(SessionHTTP.lastShareBody["profile_id"] as? Int == 1)
        precondition(SessionHTTP.lastShareBody["start_date"] == nil && SessionHTTP.lastShareBody["end_date"] == nil)
        SessionHTTP.ignoreSelection = true
        let incompatible = NativeSharingStore(session: session)
        await incompatible.create(title: "Must not broaden", start: startDate, end: endDate, hours: 24, mediaIDs: [7])
        precondition(incompatible.created == nil && !incompatible.error.isEmpty && SessionHTTP.shareRevoked)
        SessionHTTP.ignoreSelection = false
        let unsafe = try JSONDecoder().decode(NativeShare.self, from: Data(#"{"id":1,"title":"","start_date":"2026-11-08","end_date":"2026-11-09","expires_at":"2099-01-01T00:00:00Z","expired":false,"revoked":false,"token":"../../outside?secret"}"#.utf8))
        precondition(unsafe.link(site: site) == nil)
        let savedShare = try JSONDecoder().decode(NativeShare.self, from: Data(#"{"id":42,"title":"","start_date":"2026-11-08","end_date":"2026-11-09","expires_at":"2099-01-01T00:00:00Z","expired":false,"revoked":false,"link_available":true}"#.utf8))
        let savedURL = await sharing.link(for: savedShare)
        precondition(savedURL?.absoluteString == "https://native.invalid/yearly/share/saved_share_token")
        await sharing.createCopy(of: savedShare, hours: 18)
        precondition(sharing.created?.link(site: site)?.absoluteString == "https://native.invalid/yearly/share/copy_share_token")
        let expiredLink = try JSONDecoder().decode(NativeShare.self, from: Data(#"{"id":1,"title":"","start_date":"2026-11-08","end_date":"2026-11-09","expires_at":"2020-01-01T00:00:00Z","expired":false,"revoked":false,"token":"synthetic_expired"}"#.utf8))
        precondition(expiredLink.link(site: site) == nil && !expiredLink.usable)
        let own = try JSONDecoder().decode(NativeTimelineItem.self, from: Data(#"{"id":9,"owner_id":1,"can_edit":true}"#.utf8))
        let locked = try JSONDecoder().decode(NativeTimelineItem.self, from: Data(#"{"id":10,"owner_id":2,"can_edit":false}"#.utf8))
        precondition(own.editable(by: session.account) && !locked.editable(by: session.account))
        precondition(!locked.editable(by: nil))
        let beforeLockedReorder = SessionHTTP.requests.count
        await timeline.reorder(own, relativeTo: locked)
        precondition(SessionHTTP.requests.count == beforeLockedReorder)
        await timeline.loadUploaders()
        precondition(timeline.uploaders.map(\.id) == [1, 2])
        let uploadersCached = SessionHTTP.requests.count
        await timeline.loadUploaders()
        precondition(SessionHTTP.requests.count == uploadersCached, "uploader cache hit")
        try await session.write("/media/42", json: ["title": "cache invalidation"])
        await timeline.loadUploaders()
        precondition(SessionHTTP.requests.count == uploadersCached + 2, "write invalidates uploader list")
        SessionHTTP.uploadersEmpty = true
        await timeline.loadUploaders(refresh: true)
        precondition(timeline.uploaders.isEmpty)
        let emptyUploaderCached = SessionHTTP.requests.count
        await timeline.loadUploaders()
        precondition(SessionHTTP.requests.count == emptyUploaderCached, "empty uploader result is cached")
        SessionHTTP.uploadersEmpty = false
        await timeline.loadUploaders(refresh: true)
        timeline.focusOnUploads([])
        timeline.resetFilters()
        timeline.uploaderID = 2
        precondition(timeline.hasFilters)
        await timeline.load(refresh: true)
        precondition(SessionHTTP.requests.last?.url?.query?.contains("owner_id=2") == true)
        precondition(SessionHTTP.requests.last?.url?.query?.contains("cursor=") == false)
        timeline.resetFilters()
        precondition(timeline.uploaderID == nil && !timeline.hasFilters)
        let logs: NativeAuditPage = try await session.get("/audit-logs?resource_type=media&resource_id=42")
        precondition(logs.items[0].changes["title"]?.before?.display == "old")
        precondition(logs.items[0].changes["password"]?.changed == true)
        precondition(logs.items[0].changes["tags"]?.after?.display == "[family]")
        precondition(!NativeAuditLabels.time(logs.items[0].created_at).isEmpty)
        let accounts = NativeAccountsStore(session: session)
        let beforeAccounts = SessionHTTP.requests.count
        do { try await accounts.save(existing: nil, username: "new", password: "synthetic-password", role: "admin", active: true); fatalError("member created account") }
        catch { precondition(SessionHTTP.requests.count == beforeAccounts) }
        SessionHTTP.role = "admin"
        await session.restore()
        precondition(locked.editable(by: session.account), "administrator can edit all content")
        await accounts.load()
        precondition(accounts.users.count == 2)
        let displayUser = try JSONDecoder().decode(NativeManagedUser.self, from: Data(#"{"id":4,"username":"family-login","nickname":"小禾爸爸","role":"member","active":true}"#.utf8))
        precondition(displayUser.displayName == "小禾爸爸" && accounts.users[0].displayName == "synthetic")
        try await accounts.save(existing: accounts.users[0], username: "synthetic", nickname: "  青禾  ", password: "", role: "admin", active: true)
        precondition(session.account?.id == 1 && session.account?.displayName == "青禾" && !store.values.isEmpty, "nickname updates the current session without signing out")
        await timeline.loadUploaders()
        precondition(timeline.uploaders[0].displayName == "青禾" && timeline.uploaders[1].displayName == "明月", "nickname write invalidates cached uploader names")
        try await accounts.save(existing: accounts.users[0], username: "synthetic", nickname: "", password: "", role: "admin", active: true)
        precondition(session.account?.displayName == "synthetic", "clearing nickname falls back to the login username")
        let cleared = SessionHTTP.requests.last { $0.url?.path == "/yearly/api/users/1" }!
        let clearedBody = try JSONSerialization.jsonObject(with: SessionHTTP.bodyData(cleared)) as? [String: Any]
        precondition(clearedBody?["nickname"] as? String == "")
        let other = accounts.users[1]
        try await accounts.save(existing: other, username: "renamed", password: "", role: "member", active: true)
        let accountEdit = SessionHTTP.requests.last { $0.url?.path == "/yearly/api/users/2" }!
        let accountEditBody = try JSONSerialization.jsonObject(with: SessionHTTP.bodyData(accountEdit)) as! [String: Any]
        precondition(accountEditBody["password"] is NSNull && accountEditBody["active"] as? Bool == true)
        try await accounts.save(existing: nil, username: "new", password: "synthetic-password", role: "member", active: true)
        precondition(SessionHTTP.requests.contains { $0.url?.path == "/yearly/api/users" && $0.httpMethod == "POST" })
        SessionHTTP.usersFail = true
        await accounts.load()
        precondition(!accounts.error.isEmpty && accounts.users.count == 2 && !accounts.loading)
        SessionHTTP.usersFail = false
        SessionHTTP.writeFailure = passwordFailure
        do { try await session.changePassword(current: "synthetic-current", new: "synthetic-new-password"); fatalError("validation must fail") }
        catch { precondition(friendly(error) == "新密码至少需要 12 个字符。" && session.account != nil && !store.values.isEmpty) }
        SessionHTTP.writeFailure = #"{"detail":[{"type":"string_too_long","loc":["body","title"],"ctx":{"max_length":255}}]}"#
        do { try await session.write("/media/42", json: ["title": "synthetic"]); fatalError("validation must fail") }
        catch { precondition(friendly(error) == "标题最多允许 255 个字符。") }
        SessionHTTP.writeFailure = nil
        try await session.changePassword(current: "not-saved-password", new: "synthetic-new-password")
        precondition(session.account == nil && store.values.isEmpty, "changing password removes local and persisted session")
        try await session.login(username: "synthetic", password: "synthetic-new-password", captcha: captcha, answer: "ABCDE")
        let selfAccount = accounts.users[0]
        try await accounts.save(existing: selfAccount, username: "renamed-admin", password: "", role: "admin", active: true)
        precondition(session.account == nil && store.values.isEmpty, "editing current credentials requires login")
        SessionHTTP.role = "member"
        try await session.login(username: "synthetic", password: "synthetic-new-password", captcha: captcha, answer: "ABCDE")
        let restored = NativeSession(site: site, store: store, transport: transport, cacheDirectory: cacheDirectory)
        await restored.restore()
        precondition(restored.account?.id == 1)
        let otherSite = NativeSession(site: SiteOrigin("https://native.invalid/other/")!, store: store, transport: transport, cacheDirectory: cacheDirectory)
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
        let expired = NativeSession(site: site, store: store, transport: transport, cacheDirectory: cacheDirectory)
        await expired.restore()
        precondition(expired.account == nil && store.values.isEmpty)
        SessionHTTP.secureCookie = false
        do { try await expired.login(username: "synthetic", password: "not-saved-password", captcha: captcha, answer: "ABCDE"); fatalError("insecure cookie accepted") }
        catch { precondition(expired.account == nil && store.values.isEmpty) }
        print("Native session mocks passed: captcha, login, Keychain boundary, app-path isolation, CSRF, role, expiry, logout, native timeline search/date/type/order, account management/session invalidation, ownership, audit values, uploader filter/cache, share create/revoke/scope/role/expiry, HTTPS Cookie requirements; no live network.")
    }
}

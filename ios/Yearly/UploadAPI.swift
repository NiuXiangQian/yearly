import Foundation

// FastAPI uses a string for business errors and an array for field validation errors.
func nativeResponseDetail(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let detail = json["detail"] as? String, !detail.isEmpty { return String(detail.prefix(300)) }
    guard let issues = json["detail"] as? [[String: Any]], !issues.isEmpty else { return nil }
    let fields = ["username": "用户名", "password": "密码", "new_password": "新密码", "old_password": "当前密码",
                  "title": "标题", "name": "名称", "content": "日记内容", "remark": "备注", "batch_name": "批次名称",
                  "location_name": "地点名称", "latitude": "纬度", "longitude": "经度", "tags": "标签",
                  "corrected_offset_minutes": "时区偏移", "child_ids": "人物与宠物", "media_ids": "影像",
                  "description": "档案介绍", "nickname": "昵称", "captcha": "验证码", "hours": "有效期"]
    let messages = issues.prefix(3).map { issue -> String in
        let key = (issue["loc"] as? [Any])?.compactMap { $0 as? String }.last ?? ""
        let field = fields[key] ?? "输入内容"
        let context = issue["ctx"] as? [String: Any] ?? [:]
        switch issue["type"] as? String {
        case "string_too_short": return "\(field)至少需要 \(context["min_length"] ?? "指定数量") 个字符。"
        case "string_too_long": return "\(field)最多允许 \(context["max_length"] ?? "指定数量") 个字符。"
        case "too_short": return "\(field)至少需要 \(context["min_length"] ?? "指定数量") 项。"
        case "too_long": return "\(field)最多允许 \(context["max_length"] ?? "指定数量") 项。"
        case "missing": return "请填写\(field)。"
        case "string_pattern_mismatch" where key == "username": return "用户名只能包含文字、数字、下划线、点、@ 和短横线。"
        case "greater_than_equal": return "\(field)不能小于 \(context["ge"] ?? "规定下限")。"
        case "less_than_equal": return "\(field)不能大于 \(context["le"] ?? "规定上限")。"
        case "int_parsing", "int_type": return "\(field)须为整数。"
        case "float_parsing", "float_type", "finite_number": return "\(field)须为有效数字。"
        case "value_error":
            let message = (issue["msg"] as? String ?? "").replacingOccurrences(of: "Value error, ", with: "")
            if message.range(of: #"\p{Han}"#, options: .regularExpression) != nil { return "\(field)：\(message)" }
            fallthrough
        default: return "\(field)不符合要求，请检查后重试。"
        }
    }
    return String(messages.joined(separator: "\n").prefix(300))
}

struct UploadAccount: Decodable {
    let id: Int
    let role: String
    let csrf_token: String
    var username: String? = nil
    var nickname: String? = nil
    var displayName: String { if let nickname, !nickname.isEmpty { return nickname }; return username ?? "家庭成员" }
    var roleLabel: String { role == "admin" ? "管理员" : role == "member" ? "普通账户" : "只读访客" }
    func canEdit(ownerID: Int?, allowed: Bool?) -> Bool {
        role == "admin" || (role == "member" && (allowed ?? (ownerID == id)))
    }
}
struct UploadProfile: Decodable, Identifiable {
    let id: Int
    let name: String
    let nickname: String
    let profile_type: String
    let relationship: String?
    let species: String?
    let breed: String?
    let birthday: String?
    let age: String?
    let birth_time: String?
    let gender: String?
    let description: String?
    let growth_enabled: Bool?
    let theme_color: String?
    let sort_order: Int?
    let status: String?
    let avatar_media_id: Int?
    var can_edit: Bool?
    var owner_id: Int?
    var owner_name: String?
    var updated_by_name: String?
    var updated_at: String?
    func editable(by account: UploadAccount?) -> Bool { account?.canEdit(ownerID: owner_id, allowed: can_edit) ?? false }
    var isChild: Bool { profile_type == "child" || (profile_type == "person" && relationship == "孩子") }
    var label: String { (nickname.isEmpty ? name : nickname) + (profile_type == "pet" ? " · 宠物" : isChild ? " · 孩子" : " · 人物") }
}

// No redirects, disk cookies, shared credential storage or response cache in native networking.
// Native login stores only the session token in Keychain. Cookies are injected in memory.
final class UploadRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let progress: (@Sendable (Int64) -> Void)?

    init(progress: (@Sendable (Int64) -> Void)? = nil) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class UploadAPI: UploadService {
    let site: SiteOrigin
    let ownerID: Int?
    private let cookieProvider: () async -> [HTTPCookie]
    private let session: URLSession
    private let unauthorized: ((String) -> Void)?
    private let backgroundTransport: BackgroundUploadTransport?
    var onBackgroundWake: (@MainActor () -> Void)?
    private var usesBackgroundSession = false
    private var changeTransferRoute: ((Bool) -> Void)?

    func setBackground(_ background: Bool) {
        guard backgroundTransport != nil, background != usesBackgroundSession else { return }
        usesBackgroundSession = background
        changeTransferRoute?(background)
    }

    // Cumulative bytes for the current PUT attempt. nil discards that attempt's progress.
    var onPartProgress: ((Int64?) -> Void)?
    private var activePart: UUID?

    // Injectable boundaries let tests prove credential isolation without a real account or network.
    init(site: SiteOrigin, ownerID: Int? = nil, cookieProvider: @escaping () async -> [HTTPCookie], session: URLSession? = nil, backgroundTransport: BackgroundUploadTransport? = nil, unauthorized: ((String) -> Void)? = nil) {
        self.site = site
        self.cookieProvider = cookieProvider
        self.ownerID = ownerID
        self.unauthorized = unauthorized
        self.backgroundTransport = backgroundTransport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        self.session = session ?? URLSession(configuration: configuration, delegate: UploadRedirectPolicy(), delegateQueue: nil)
    }

    private func cookie() async throws -> String {
        let cookies = await cookieProvider()
        guard let cookie = cookies.first(where: {
            $0.name == "yearly_session" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == site.url.host?.lowercased()
            && $0.path == site.basePath && $0.isSecure && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }) else { throw UploadHTTPError(status: 401, isOSS: false) }
        return HTTPCookie.requestHeaderFields(with: [cookie])["Cookie"] ?? ""
    }

    private func send(_ path: String, method: String = "GET", body: Data? = nil, cookie: String,
                      csrf: String? = nil, key: UUID? = nil) async throws -> Data {
        guard let url = URL(string: "api" + path, relativeTo: site.url)?.absoluteURL, site.contains(url) else {
            throw UploadFailure(message: "无效的家庭站点请求。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET" {
            request.setValue(site.origin, forHTTPHeaderField: "Origin")
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        }
        if let key { request.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { unauthorized?(cookie) }
            throw UploadHTTPError(status: status, isOSS: false, detail: nativeResponseDetail(data))
        }
        return data
    }

    private func authenticate(cookie: String) async throws -> UploadAccount {
        let account = try JSONDecoder().decode(UploadAccount.self, from: await send("/auth/me", cookie: cookie))
        guard ["admin", "member"].contains(account.role), ownerID == nil || account.id == ownerID else {
            throw UploadHTTPError(status: 403, isOSS: false)
        }
        return account
    }
    func account() async throws -> UploadAccount { try await authenticate(cookie: cookie()) }
    private func request(_ path: String, body: Data? = nil, key: UUID? = nil) async throws -> Data {
        let cookie = try await cookie()
        // Revalidate the account and obtain the CSRF token with the very same cookie.
        let account = try await authenticate(cookie: cookie)
        return try await send(path, method: body == nil ? "GET" : "POST", body: body, cookie: cookie, csrf: account.csrf_token, key: key)
    }
    func profiles() async throws -> [UploadProfile] {
        try JSONDecoder().decode([UploadProfile].self, from: await request("/children"))
    }
    func create(body: Data, key: UUID) async throws -> UploadCreation {
        try JSONDecoder().decode(UploadCreation.self, from: await request("/uploads", body: body, key: key))
    }
    func status(_ task: RemoteUpload) async throws -> RemoteStatus {
        try JSONDecoder().decode(RemoteStatus.self, from: await request("/uploads/\(task.id)"))
    }
    func sign(_ task: RemoteUpload, number: Int) async throws -> URL {
        struct Signed: Decodable { let url: String }
        let signed = try JSONDecoder().decode(Signed.self, from: await request("/uploads/\(task.id)/sign?number=\(number)", body: Data("{}".utf8)))
        guard let url = AppConfiguration.httpsURL(signed.url) else { throw UploadFailure(message: "服务端返回了不安全的上传地址。") }
        return url
    }
    func put(_ data: Data, to url: URL) async throws {
        guard AppConfiguration.httpsURL(url.absoluteString) != nil else { throw UploadFailure(message: "无效上传地址。") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        // Never send Cookie, Origin, CSRF or Authorization to OSS.
        let stagedFile = try await backgroundTransport?.stage(data)
        var handedOff: BackgroundUploadTransport.Transfer?
        let part = UUID()
        let partSize = Int64(data.count)
        let wake = onBackgroundWake
        var lastProgress: ContinuousClock.Instant?
        activePart = part
        defer {
            activePart = nil
            changeTransferRoute = nil
            handedOff?.cancel()
            if let stagedFile { try? FileManager.default.removeItem(at: stagedFile) }
        }

        func progress(fromBackground: Bool) -> @Sendable (Int64) -> Void {
            { [weak self] bytes in
                Task { @MainActor in
                    let now = ContinuousClock.now
                    guard let self, self.activePart == part, self.usesBackgroundSession == fromBackground,
                          lastProgress.map({ $0.duration(to: now) >= .milliseconds(250) }) ?? true else { return }
                    lastProgress = now
                    self.onPartProgress?(min(bytes, partSize))
                }
            }
        }

        let backgroundProgress = progress(fromBackground: true)
        let foregroundProgress = progress(fromBackground: false)
        while true {
            try Task.checkCancellation()
            lastProgress = nil
            onPartProgress?(0)
            let attempt: Task<URLResponse, Error>
            if usesBackgroundSession, let backgroundTransport, let stagedFile {
                let transfer = handedOff ?? backgroundTransport.schedule(request, file: stagedFile,
                                                                        progress: backgroundProgress, wake: wake)
                handedOff = nil
                attempt = Task { try await transfer.response() }
                changeTransferRoute = { _ in attempt.cancel() }
            } else {
                let delegate = UploadRedirectPolicy(progress: foregroundProgress)
                attempt = Task { try await session.upload(for: request, from: data, delegate: delegate).1 }
                changeTransferRoute = { [backgroundTransport] background in
                    if background, let backgroundTransport, let stagedFile {
                        // Submit the file to iOS while the scene is still deactivating.
                        handedOff = backgroundTransport.schedule(request, file: stagedFile,
                                                                  progress: backgroundProgress, wake: wake)
                    } else {
                        handedOff?.cancel()
                        handedOff = nil
                    }
                    attempt.cancel()
                }
            }
            do {
                let response = try await withTaskCancellationHandler { try await attempt.value } onCancel: { attempt.cancel() }
                try Task.checkCancellation()
                if attempt.isCancelled {
                    onPartProgress?(nil)
                    continue
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw UploadHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, isOSS: true)
                }
                onPartProgress?(partSize)
                return
            } catch {
                try Task.checkCancellation()
                onPartProgress?(nil)
                // A scene transition restarts the same PUT with identical bytes and part number.
                if attempt.isCancelled { continue }
                throw error
            }
        }
    }
    func complete(_ task: RemoteUpload) async throws {
        struct Completed: Decodable { let status: String }
        let result = try JSONDecoder().decode(Completed.self, from: await request("/uploads/\(task.id)/complete", body: Data("{}".utf8)))
        guard result.status == "complete" else { throw UploadFailure(message: "服务端尚未确认完整性。") }
    }
}

// Only signed OSS PUTs use this session. Authenticated API calls retain the ephemeral,
// no-redirect session above: background sessions always follow redirects on iOS.
// The daemon owns file-backed transfers while the app is suspended. Continuations are
// deliberately process-local; after termination the persisted queue reconciles OSS parts.
final class BackgroundUploadTransport: NSObject, URLSessionTaskDelegate {
    static let identifier = "family.yearly.original-parts"
    static let shared = BackgroundUploadTransport()

    struct Transfer: Sendable {
        let task: URLSessionUploadTask
        let result: AsyncThrowingStream<URLResponse, Error>

        func response() async throws -> URLResponse {
            try await withTaskCancellationHandler {
                var iterator = result.makeAsyncIterator()
                guard let response = try await iterator.next() else { throw CancellationError() }
                return response
            } onCancel: { task.cancel() }
        }

        func cancel() { task.cancel() }
    }

    private struct Pending {
        let result: AsyncThrowingStream<URLResponse, Error>.Continuation
        let progress: @Sendable (Int64) -> Void
        let wake: (@MainActor () -> Void)?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var eventsCompletion: (() -> Void)?
    private let directory: URL
    private var session: URLSession!
    var hasPendingTransfers: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }

    // An injected configuration permits offline URLProtocol tests of the real file path.
    init(configuration: URLSessionConfiguration? = nil, directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("YearlyBackgroundParts", isDirectory: true)
        super.init()
        let config: URLSessionConfiguration
        if let configuration { config = configuration }
        else {
            config = .background(withIdentifier: Self.identifier)
            config.isDiscretionary = false
            #if os(iOS)
            config.sessionSendsLaunchEvents = true
            #endif
        }
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        // Remove staging files abandoned before task creation, without touching files
        // referenced by reconnected daemon tasks or requests staged after this launch.
        let launched = Date(), root = self.directory
        session.getAllTasks { tasks in
            let active = Set(tasks.compactMap(\.taskDescription))
            for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                guard !active.contains(file.lastPathComponent),
                      let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                      created < launched else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func stage(_ data: Data) async throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString + ".part")
        try await Task.detached(priority: .utility) { [directory] in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
        }.value
        return file
    }

    func schedule(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Int64) -> Void,
                  wake: (@MainActor () -> Void)?) -> Transfer {
        let (stream, result) = AsyncThrowingStream<URLResponse, Error>.makeStream(of: URLResponse.self)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = file.lastPathComponent
        lock.withLock { pending[task.taskIdentifier] = Pending(result: result, progress: progress, wake: wake) }
        task.resume()
        return Transfer(task: task, result: stream)
    }

    func handleEvents(completion: @escaping () -> Void) {
        lock.lock(); eventsCompletion = completion; lock.unlock()
    }
    func invalidate() { session.invalidateAndCancel() }
    func cancelRecoveredTransfers() async {
        for task in await session.allTasks {
            if lock.withLock({ pending[task.taskIdentifier] == nil }) { task.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let record = pending[task.taskIdentifier]; lock.unlock()
        record?.progress(totalBytesSent)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response
        let name = task.taskDescription
        let identifier = task.taskIdentifier
        DispatchQueue.main.async { [self] in
            // Keep the transfer visible to the expiration handler until its callback runs.
            guard let record = lock.withLock({ pending.removeValue(forKey: identifier) }) else {
                if let name, name.hasSuffix(".part"), UUID(uuidString: String(name.dropLast(5))) != nil {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
                return
            }
            record.wake?() // Obtain execution time for sign/checkpoint/complete before resuming the queue.
            if let error { record.result.finish(throwing: error) }
            else if let response {
                record.result.yield(response)
                record.result.finish()
            } else { record.result.finish(throwing: URLError(.badServerResponse)) }
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let completion = eventsCompletion; eventsCompletion = nil; lock.unlock()
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
}

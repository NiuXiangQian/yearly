import Foundation
import Combine
import Security

struct NativeAPIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct SessionCredential: Codable {
    let value: String
    let expires: Date
}
protocol SessionCredentialStore {
    func read(site: String) throws -> SessionCredential?
    func write(_ credential: SessionCredential?, site: String) throws
}
struct KeychainSessionStore: SessionCredentialStore {
    private func query(_ site: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "family.yearly.native-session",
         kSecAttrAccount as String: site]
    }
    func read(site: String) throws -> SessionCredential? {
        var query = query(site)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw UploadFailure(message: "无法读取安全登录状态，请解锁设备后重试。")
        }
        return try JSONDecoder().decode(SessionCredential.self, from: data)
    }
    func write(_ credential: SessionCredential?, site: String) throws {
        let query = query(site)
        guard let credential else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw UploadFailure(message: "无法清除安全登录状态，请解锁设备后重试。")
            }
            return
        }
        let data = try JSONEncoder().encode(credential)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw UploadFailure(message: "无法安全保存登录状态，请解锁设备后重试。") }
    }
}

struct LoginCaptcha: Decodable {
    let id: String
    let image: String
    var png: Data? {
        let prefix = "data:image/png;base64,"
        guard image.hasPrefix(prefix) else { return nil }
        return Data(base64Encoded: String(image.dropFirst(prefix.count)))
    }
}

@MainActor final class NativeSession: ObservableObject {
    let site: SiteOrigin
    @Published private(set) var account: UploadAccount?
    @Published private(set) var restoring = true
    @Published var error = ""
    private let store: SessionCredentialStore
    private let transport: URLSession
    private var credential: SessionCredential?
    private var generation = 0
    var canEdit: Bool { ["admin", "member"].contains(account?.role ?? "") }

    init(site: SiteOrigin, store: SessionCredentialStore = KeychainSessionStore(), transport: URLSession? = nil) {
        self.site = site
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        self.transport = transport ?? URLSession(configuration: config, delegate: UploadRedirectPolicy(), delegateQueue: nil)
    }
    func cookies() -> [HTTPCookie] {
        if let credential, credential.expires <= Date() { expire() }
        guard account != nil, let credential, credential.expires > Date(), let host = site.url.host,
              let cookie = HTTPCookie(properties: [.name: "yearly_session", .value: credential.value,
                .domain: host, .path: site.basePath, .secure: "TRUE", .expires: credential.expires]) else { return [] }
        return [cookie]
    }
    private func send(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), let url = URL(string: "api" + path, relativeTo: site.url)?.absoluteURL, site.contains(url) else {
            throw UploadFailure(message: "无效的家庭站点请求。")
        }
        let usedCredential = authenticated ? credential : nil
        if authenticated && (usedCredential == nil || usedCredential!.expires <= Date()) {
            expire()
            throw NativeAPIError(status: 401, message: "请先登录家庭账号。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let usedCredential { request.setValue("yearly_session=\(usedCredential.value)", forHTTPHeaderField: "Cookie") }
        if method != "GET" {
            request.setValue(site.origin, forHTTPHeaderField: "Origin")
            if authenticated { request.setValue(account?.csrf_token, forHTTPHeaderField: "X-CSRF-Token") }
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadFailure(message: "家庭站点响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 && authenticated && credential?.value == usedCredential?.value {
                expire()
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (json?["detail"] as? String).map { String($0.prefix(300)) }
            throw NativeAPIError(status: http.statusCode, message: detail ?? "家庭站点请求失败（\(http.statusCode)）。")
        }
        return (data, http)
    }
    func restore() async {
        let current = generation
        restoring = true
        defer { restoring = false }
        do {
            credential = try store.read(site: site.url.absoluteString)
            guard let credential else { return }
            if credential.expires <= Date() { try store.write(nil, site: site.url.absoluteString); self.credential = nil; return }
            let (data, _) = try await send("/auth/me")
            guard current == generation else { return }
            account = try JSONDecoder().decode(UploadAccount.self, from: data)
            error = ""
        } catch { if current == generation { self.error = friendly(error) } }
    }
    func captcha() async throws -> LoginCaptcha {
        let (data, _) = try await send("/auth/captcha", authenticated: false)
        return try JSONDecoder().decode(LoginCaptcha.self, from: data)
    }
    func login(username: String, password: String, captcha: LoginCaptcha, answer: String) async throws {
        generation += 1
        let current = generation
        let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password, "captcha_id": captcha.id, "captcha": answer])
        let (data, response) = try await send("/auth/login", method: "POST", body: body, authenticated: false)
        guard current == generation else { throw CancellationError() }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let key = field.key as? String, let value = field.value as? String { result[key] = value }
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: site.url).first(where: {
            $0.name == "yearly_session" && $0.isSecure && $0.isHTTPOnly && $0.path == site.basePath &&
            $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == site.url.host?.lowercased()
        }), let expires = cookie.expiresDate, expires > Date(), !cookie.value.contains("\r"), !cookie.value.contains("\n") else {
            throw UploadFailure(message: "站点未提供安全会话，请检查 HTTPS 与 Cookie 路径配置。")
        }
        let account = try JSONDecoder().decode(UploadAccount.self, from: data)
        let saved = SessionCredential(value: cookie.value, expires: expires)
        try store.write(saved, site: site.url.absoluteString)
        credential = saved; self.account = account; error = ""
    }
    func logout() async throws {
        generation += 1
        var failure: Error?
        if account != nil { do { _ = try await send("/auth/logout", method: "POST", body: Data("{}".utf8)) } catch { failure = error } }
        account = nil; credential = nil
        try store.write(nil, site: site.url.absoluteString)
        if let failure { throw failure }
    }
    func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, _) = try await send(path)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func write(_ path: String, method: String = "PUT", json: [String: Any]) async throws {
        guard canEdit else { throw NativeAPIError(status: 403, message: "此账号为只读账号。") }
        _ = try await send(path, method: method, body: JSONSerialization.data(withJSONObject: json))
    }
    func post<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        guard canEdit else { throw NativeAPIError(status: 403, message: "此账号为只读账号。") }
        let (data, _) = try await send(path, method: "POST", body: JSONSerialization.data(withJSONObject: json))
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func expire() {
        generation += 1
        account = nil; credential = nil
        error = "登录已失效，请重新登录后继续未完成任务。"
        do { try store.write(nil, site: site.url.absoluteString) }
        catch { self.error = friendly(error) }
    }
    func uploadAPI(ownerID: Int? = nil) -> UploadAPI {
        UploadAPI(site: site, ownerID: ownerID, cookieProvider: { [weak self] in self?.cookies() ?? [] }, unauthorized: { [weak self] rejected in
            guard let self, let credential = self.credential,
                  rejected == "yearly_session=\(credential.value)" else { return }
            self.expire()
        })
    }
}
func friendly(_ error: Error) -> String {
    if error is CancellationError { return "操作已取消。" }
    if error is URLError { return "网络连接失败，请检查网络和站点地址后重试。" }
    return error.localizedDescription
}

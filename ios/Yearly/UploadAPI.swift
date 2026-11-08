import Foundation
import WebKit

struct UploadAccount: Decodable { let id: Int; let role: String; let csrf_token: String }
struct UploadProfile: Decodable, Identifiable {
    let id: Int
    let name: String
    let nickname: String
    let profile_type: String
    var label: String { (nickname.isEmpty ? name : nickname) + (profile_type == "pet" ? " · 宠物" : profile_type == "child" ? " · 孩子" : " · 人物") }
}

// No redirects, disk cookies, shared credential storage or response cache in native networking.
// Login remains in the existing WKWebView. Session cookies are copied in memory for each API call.
final class UploadRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class UploadAPI: UploadService {
    let site: SiteOrigin
    let ownerID: Int?
    private let cookieProvider: () async -> [HTTPCookie]
    private let session: URLSession

    convenience init(site: SiteOrigin, cookieStore: WKHTTPCookieStore, ownerID: Int? = nil) {
        self.init(site: site, ownerID: ownerID, cookieProvider: { await cookieStore.allCookies() })
    }
    // Injectable boundaries let tests prove credential isolation without a real account or network.
    init(site: SiteOrigin, ownerID: Int? = nil, cookieProvider: @escaping () async -> [HTTPCookie], session: URLSession? = nil) {
        self.site = site
        self.cookieProvider = cookieProvider
        self.ownerID = ownerID
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
                      csrf: String? = nil, key: UUID? = nil, requireIdempotency: Bool = false) async throws -> Data {
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
            throw UploadHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, isOSS: false)
        }
        if requireIdempotency && http.value(forHTTPHeaderField: "X-Yearly-Upload-Protocol") != "idempotent-v1" {
            throw UploadFailure(message: "家庭服务尚未支持可靠的原生任务恢复，请先更新本分支的上传接口。未创建上传任务。")
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
        if key != nil {
            _ = try await send("/uploads", cookie: cookie, requireIdempotency: true)
        }
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
        let (_, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, isOSS: true)
        }
    }
    func complete(_ task: RemoteUpload) async throws {
        struct Completed: Decodable { let status: String }
        let result = try JSONDecoder().decode(Completed.self, from: await request("/uploads/\(task.id)/complete", body: Data("{}".utf8)))
        guard result.status == "complete" else { throw UploadFailure(message: "服务端尚未确认完整性。") }
    }
}

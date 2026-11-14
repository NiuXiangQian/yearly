import Foundation

// Synthetic family data shared by native HTTP tests and the local screenshot harness.
final class MemoryReviewCredentials: SessionCredentialStore {
    func read(site: String) throws -> SessionCredential? { SessionCredential(value: "synthetic", expires: Date().addingTimeInterval(3600)) }
    func write(_ credential: SessionCredential?, site: String) throws {}
}
final class MemoryReviewHTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var failWrites = false
    static var failCurationReads = false
    static var role = "admin"
    static var empty = false
    static var omitConfirmationCounts = false
    static let media: [String: Any] = ["id": 42, "title": "公园里的周末", "media_type": "photo", "timeline_day": "2026-11-01", "tags": ["周末"], "remark": "原有小记", "child_ids": [7], "files": []]
    static let candidate: [String: Any] = ["child_id": 7, "name": "家人甲", "similarity": 0.91, "reference_thumbnail": ""]
    static var face: [String: Any] { ["id": 21, "thumbnail": "", "child_id": NSNull(), "ignored": false, "frame_seconds": 2.5, "auto_assigned": false, "candidates": [candidate], "media": media] }
    static var dog: [String: Any] { ["index": 0, "thumbnail": "", "appearance": "浅色毛、垂耳的小狗", "child_id": NSNull(), "ignored": false, "frame_seconds": NSNull(), "candidates": [["child_id": 8, "name": "多多", "similarity": 0.88, "reference_thumbnail": ""]]] }
    static let organizationSettings: [String: Any] = ["tags_enabled": true, "people_enabled": true, "tag_rules": [String: String](), "person_rules": [String: String]()]
    static var organizationEntry: [String: Any] {
        ["id": 31, "auto_linked": 2, "auto_reset": 0, "kind": "tags", "status": "pending", "automatic": true, "media": media,
         "before": ["tags": ["周末"]], "proposed": ["tags": ["公园"]], "current": ["tags": ["公园"], "decisions": ["公园": "公园"]],
         "evidence": ["tags": [["name": "公园", "evidence": "在公园散步", "rule": "default"]], "description": "家人在公园散步。", "model": "synthetic"],
         "events": [["action": "applied", "at": "2026-11-13T10:00:00", "actor_name": "自动整理", "value": ["tags": ["公园"]]]],
         "names": [String: String](), "thumbnail": "", "frame_seconds": NSNull(), "created_at": "2026-11-13T10:00:00", "updated_at": "2026-11-13T10:00:00"]
    }
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let path = request.url!.path.replacingOccurrences(of: "/yearly/api", with: "")
        let writing = request.httpMethod != "GET"
        var response: Any = [String: String]()
        var status = 200
        if Self.failCurationReads && path == "/curation/groups" { status = 503; response = ["detail": "模拟刷新失败"] }
        else if Self.failWrites && writing { status = 503; response = ["detail": "模拟保存失败"] }
        else {
            switch path {
            case "/auth/me": response = ["id": 1, "username": "演示管理员", "role": Self.role, "csrf_token": "synthetic-csrf"]
            case "/ai-search/status": response = ["enabled": true, "total": 1, "indexed": 1, "failed": 0]
            case "/ai-search": response = ["items": [Self.media], "page": 1, "page_size": 20, "search_id": "sample", "total": 1, "indexed": 1]
            case "/children": response = [["id": 7, "name": "家人甲", "nickname": "", "profile_type": "person"], ["id": 8, "name": "多多", "nickname": "", "profile_type": "pet", "species": "狗"]]
            case "/curation/groups": response = ["items": [["key": "42", "kind": "single", "items": [["media": Self.media, "quality": NSNull()]]]], "next_cursor": NSNull(), "group_count": 1, "unfiled_media": 1, "total_media": 1, "quality_enabled": true]
            case "/curation/batch": response = ["count": 1, "undo_token": "synthetic-batch"]
            case "/curation/undo/synthetic-batch": response = ["ok": true]
            case "/curation/media/42/quality": response = ["frames": [["frame": 0, "clarity": 4, "reason": "画面清楚"]], "representative": 0, "seconds": [NSNull()], "thumbnail": ""]
            case "/faces/review": response = ["enabled": true, "ready": true, "message": "", "items": Self.empty ? [] : [Self.face], "next_cursor": Self.empty ? NSNull() : 21,
                "pending_faces": Self.empty ? 0 : 12, "pending_memories": 8, "unanalysed_photos": 0, "auto_link_enabled": true]
            case "/pets/review": response = ["items": Self.empty ? [] : [["media": Self.media, "dogs": [Self.dog]]], "pending_pets": Self.empty ? 0 : 3, "unanalysed_media": 0, "next_cursor": NSNull()]
            case "/organization/settings": response = Self.organizationSettings
            case "/organization/reviews": response = ["items": Self.empty ? [] : [Self.organizationEntry], "pending": 1, "next_cursor": NSNull(), "errors": []]
            case "/organization/reviews/31": response = Self.organizationEntry
            case "/organization/run": response = ["processed": 3, "busy": false]
            case "/faces/auto-link": response = ["linked_faces": 2, "reset_faces": 1]
            case "/faces/media/42/confirm": response = Self.omitConfirmationCounts ? [:] : ["auto_linked": 2, "auto_reset": 1]
            case "/faces/analyze-next", "/pets/analyze-next": response = ["processed": [42], "failed": []]
            case "/media/42": response = Self.media
            case "/timeline": response = ["items": [], "total": 0]
            default: break
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: response)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

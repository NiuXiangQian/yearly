import Foundation
import CryptoKit

// Shared by the iOS client and the macOS mock tests. No Photos/UI dependency.
struct UploadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct UploadHTTPError: LocalizedError {
    let status: Int
    let isOSS: Bool
    var detail: String? = nil
    var errorDescription: String? {
        if isOSS { return "OSS 上传失败（\(status)），已保留分片，可重试。" }
        switch status {
        case 401: return "登录已失效，请在 App 重新登录后继续。"
        case 403: return "没有上传权限、登录账号已变化或安全校验失败，请重新登录。"
        case 400, 422: return detail ?? "上传信息不符合要求，请检查后重试。"
        case 409: return detail ?? "服务端状态或完整性校验冲突（409），未标记成功。请核查后重试。"
        case 410: return "上传任务已超过服务端 7 天有效期，请取消后重新选择原件。"
        default: return "家庭站点请求失败（\(status)），请稍后重试。"
        }
    }
}

enum UploadPhase: String, Codable {
    case selected, preparing, ready, queued, uploading, paused, failed, complete, cancelled, skipped
    var canPause: Bool { [.selected, .preparing, .queued, .uploading].contains(self) }
    var label: String {
        switch self {
        case .selected: return "等待提取"
        case .preparing: return "准备原始资源"
        case .ready: return "待确认上传"
        case .queued: return "等待上传"
        case .uploading: return "上传中"
        case .paused: return "已暂停"
        case .failed: return "失败，可重试"
        case .complete: return "已完成"
        case .cancelled: return "已取消"
        case .skipped: return "重复已跳过"
        }
    }
}
struct RemoteUpload: Codable, Equatable {
    let id: String
    let media_id: Int
    let sha256: String
    let file_size: Int64
    let file_role: String
    let part_size: Int
    var status: String
}
struct RemotePart: Codable { let number: Int; let size: Int64 }
struct RemoteStatus: Decodable { let status: String; let parts: [RemotePart] }
struct UploadCreation: Decodable {
    let media_id: Int
    let tasks: [RemoteUpload]
    let duplicate: Bool?
}
struct UploadResource: Codable, Equatable {
    var role: String
    var filename: String
    var mimeType: String
    var path: String
    var size: Int64
    var sha256: String
    var crc64: String
    var task: RemoteUpload?
    var complete = false
    var uploadedBytes: Int64 = 0

    var specification: [String: Any] {
        ["file_role": role, "original_filename": filename, "mime_type": mimeType,
         "file_size": size, "sha256": sha256, "crc64": crc64]
    }
}
struct UploadItem: Codable, Identifiable {
    var id = UUID()
    let assetIdentifier: String
    let site: String
    let ownerID: Int
    var name: String
    var mediaType: String
    var phase: UploadPhase = .selected
    var resources: [UploadResource] = []
    // This is JSON metadata, never a credential or a signed URL.
    var fields = Data("{}".utf8)
    var captureDate: String?
    var photoKitDate: Date?
    var warning = ""
    var message = ""
    var sourceByteCount: Int64?
    var childIDs: [Int] = []
    var batchName = ""
    var archiveDate: String?
    var confirmed = false
    var requestStarted = false
    var mediaID: Int?
    var duplicate = false

    var isTerminal: Bool { phase == .complete || phase == .cancelled || phase == .skipped }
    var size: Int64 { resources.reduce(0) { $0 + $1.size } }
    var uploadedBytes: Int64 {
        if phase == .complete { return size }
        return resources.reduce(0) { $0 + ($1.complete ? $1.size : $1.uploadedBytes) }
    }
    func albumArchiveDay(timeZone: TimeZone = .current) -> String? {
        guard captureDate == nil, let photoKitDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: photoKitDate)
    }
    func sameOriginals(as other: UploadItem) -> Bool {
        guard site == other.site, ownerID == other.ownerID, mediaType == other.mediaType,
              !resources.isEmpty, resources.count == other.resources.count else { return false }
        return resources.allSatisfy { file in other.resources.contains {
            $0.role == file.role && $0.sha256 == file.sha256 && $0.size == file.size
        } }
    }
    func body() throws -> Data {
        guard resources.count == (mediaType == "live_photo" ? 2 : 1),
              Set(resources.map(\.role)) == Set(mediaType == "live_photo" ? ["original", "live_video"] : ["original"]) else {
            throw UploadFailure(message: "原始资源不完整，不能创建上传。")
        }
        var json = (try JSONSerialization.jsonObject(with: fields)) as? [String: Any] ?? [:]
        json["media_type"] = mediaType
        json["files"] = resources.map(\.specification)
        json["child_ids"] = childIDs
        json["batch_name"] = batchName
        json["timeline_date"] = archiveDate as Any? ?? NSNull()
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}

struct ByteProgress {
    let processed: Int64
    let total: Int64?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(processed) / Double(total))
    }

    func remainingTime(bytesPerSecond: Double) -> Double? {
        guard let total, bytesPerSecond.isFinite, bytesPerSecond > 0, processed < total else { return nil }
        return Double(total - processed) / bytesPerSecond
    }
}

struct UploadStore {
    let directory: URL
    var manifest: URL { directory.appendingPathComponent("queue.json") }
    static let cacheLimit: Int64 = 8 * 1024 * 1024 * 1024
    static let freeReserve: Int64 = 512 * 1024 * 1024

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }
    func load() throws -> [UploadItem] {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        var items = try JSONDecoder().decode([UploadItem].self, from: Data(contentsOf: manifest))
        for i in items.indices where !items[i].isTerminal && items[i].phase != .ready && items[i].phase != .failed {
            items[i].phase = .paused
            items[i].message = "已恢复本机记录；继续时将核对服务端分片。"
        }
        return items
    }
    func save(_ items: [UploadItem]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: manifest, options: .atomic)
    }
    func itemDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func file(_ resource: UploadResource, itemID: UUID) throws -> URL {
        guard resource.path == URL(fileURLWithPath: resource.path).lastPathComponent,
              !resource.path.isEmpty, resource.path != ".", resource.path != ".." else {
            throw UploadFailure(message: "缓存路径不合法。")
        }
        return itemDirectory(itemID).appendingPathComponent(resource.path)
    }
    func removeFiles(_ id: UUID) throws {
        let url = itemDirectory(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func cacheBytes() throws -> Int64 {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
    func checkSpace() throws {
        let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
        guard (free?.int64Value ?? 0) > Self.freeReserve, try cacheBytes() < Self.cacheLimit else {
            throw UploadFailure(message: "原件缓存达到 8 GiB 或可用空间不足 512 MiB。请先上传或取消部分项目，再重试。")
        }
    }
}

enum FileIntegrity {
    static let blockSize = 4 * 1024 * 1024
    // CRC64/XZ (reflected ECMA polynomial, init/xorout all ones), identical to hash-wasm / OSS.
    private static let table: [UInt64] = (0..<256).map { index in
        var crc = UInt64(index)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xC96C5795D7870F42 : 0) }
        return crc
    }
    struct Digest: Equatable { let size: Int64; let sha256: String; let crc64: String }
    static func fingerprint(_ url: URL, check: () throws -> Void = {}) throws -> Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256(), crc = UInt64.max, size: Int64 = 0
        while true {
            try check()
            // FileHandle bridges NSData. Drain each block's autoreleases, including in a
            // detached task without a UIKit run loop, so a 1 GiB file stays bounded.
            let hasData = try autoreleasepool {
                guard let data = try handle.read(upToCount: blockSize), !data.isEmpty else { return false }
                sha.update(data: data)
                for byte in data { crc = table[Int((crc ^ UInt64(byte)) & 255)] ^ (crc >> 8) }
                size += Int64(data.count)
                return true
            }
            if !hasData { break }
        }
        guard size > 0 else { throw UploadFailure(message: "原始文件为空。") }
        return Digest(size: size, sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(), crc64: String(crc ^ UInt64.max))
    }
    static func block(_ url: URL, offset: Int64, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw UploadFailure(message: "本机原件缓存不完整；请重新提取原件。")
        }
        return data
    }
}

// Select matching generations. Never mix an original photo with an edited paired video.
enum PhotoResourcePolicy {
    struct Choice: Equatable { let types: [Int]; let edited: Bool }
    static func select(types: [Int], live: Bool, video: Bool) throws -> Choice {
        let available = Set(types)
        let original = live ? [1, 9] : video ? [2] : [1]
        if Set(original).isSubset(of: available) { return Choice(types: original, edited: false) }
        let rendered = live ? [5, 10] : video ? [6] : [5]
        if Set(rendered).isSubset(of: available) { return Choice(types: rendered, edited: true) }
        throw UploadFailure(message: live ? "Live Photo 缺少同一版本的静态图或配对 MOV，未按普通照片导入。" : "没有可读取的原始或完整尺寸资源。")
    }
}

@MainActor protocol UploadService {
    func create(body: Data, key: UUID) async throws -> UploadCreation
    func status(_ task: RemoteUpload) async throws -> RemoteStatus
    func sign(_ task: RemoteUpload, number: Int) async throws -> URL
    func put(_ data: Data, to url: URL) async throws
    func complete(_ task: RemoteUpload) async throws
}

@MainActor enum MultipartUploader {
    static func uploadAvatar(_ jpeg: Data, key: UUID, service: UploadService,
                             progress: (Double) -> Void) async throws -> Int {
        guard !jpeg.isEmpty, jpeg.count <= 1024 * 1024 else {
            throw UploadFailure(message: "头像图片须小于或等于 1 MB。")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("yearly-avatar-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        #if os(iOS)
        try jpeg.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try jpeg.write(to: file, options: .atomic)
        #endif
        let digest = try await Task.detached(priority: .utility) { try FileIntegrity.fingerprint(file) }.value
        var resource = UploadResource(role: "original", filename: "avatar.jpg", mimeType: "image/jpeg",
                                      path: file.path, size: digest.size, sha256: digest.sha256, crc64: digest.crc64)
        let body = try JSONSerialization.data(withJSONObject: [
            "purpose": "avatar", "media_type": "photo", "files": [resource.specification],
        ])
        let result = try await retry { try await service.create(body: body, key: key) }
        guard result.media_id > 0 else { throw UploadFailure(message: "未获得有效的头像记录。") }
        if result.duplicate == true && result.tasks.isEmpty {
            progress(1)
            return result.media_id
        }
        guard result.tasks.count == 1, let task = result.tasks.first, task.media_id == result.media_id else {
            throw UploadFailure(message: "头像上传任务不匹配，未更改资料。")
        }
        resource.task = task
        try await upload(resource, file: file, service: service) { bytes, complete in
            progress(complete ? 1 : min(0.95, Double(bytes) / Double(resource.size)))
        }
        return result.media_id
    }

    static func retry<T>(sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                         operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                if error is CancellationError { throw error }
                let retryable: Bool
                if let http = error as? UploadHTTPError {
                    retryable = http.status >= 500 || http.status == 429 || (http.isOSS && [403, 409].contains(http.status))
                } else { retryable = (error as NSError).domain == NSURLErrorDomain }
                guard retryable && attempt < 2 else { throw error }
                try await sleep(UInt64(1 << attempt) * 1_000_000_000)
            }
        }
        throw UploadFailure(message: "重试次数已用完。")
    }
    static func upload(_ resource: UploadResource, file: URL, service: UploadService,
                       checkpoint: (Int64, Bool) throws -> Void) async throws {
        guard let task = resource.task,
              task.sha256 == resource.sha256, task.file_size == resource.size, task.file_role == resource.role,
              task.part_size > 0, task.part_size <= 64 * 1024 * 1024 else {
            throw UploadFailure(message: "服务端任务与本机原件不匹配。")
        }
        let status = try await retry { try await service.status(task) }
        if status.status == "complete" { try checkpoint(resource.size, true); return }
        guard ["pending", "uploading"].contains(status.status) else { throw UploadFailure(message: "任务当前不可续传。") }
        let size = Int64(task.part_size)
        let count = Int((resource.size + size - 1) / size)
        guard count <= 10000 else { throw UploadFailure(message: "分片数超出协议限制。") }
        var uploaded = Set<Int>(), completed: Int64 = 0
        for part in status.parts {
            guard (1...count).contains(part.number), uploaded.insert(part.number).inserted,
                  part.size == min(size, resource.size - Int64(part.number - 1) * size) else {
                throw UploadFailure(message: "服务端分片大小或序号异常，未继续上传。")
            }
            completed += part.size
        }
        try checkpoint(completed, false)
        for number in 1...count where !uploaded.contains(number) {
            try Task.checkCancellation()
            let offset = Int64(number - 1) * size
            let length = Int(min(size, resource.size - offset))
            let data = try await Task.detached(priority: .utility) { try FileIntegrity.block(file, offset: offset, count: length) }.value
            try await retry {
                // Every attempt obtains a fresh URL; a lost PUT response safely replaces the same part.
                let url = try await service.sign(task, number: number)
                try await service.put(data, to: url)
            }
            completed += Int64(length)
            try checkpoint(completed, false)
        }
        try Task.checkCancellation()
        try await retry { try await service.complete(task) }
        try checkpoint(resource.size, true)
    }
}

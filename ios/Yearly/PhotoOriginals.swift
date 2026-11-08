import Foundation
import Photos
import UniformTypeIdentifiers

// requestData is the cancellable, byte-identical streaming counterpart of writeData.
// Unlike writeData (which has no request ID), it lets us enforce a disk budget during iCloud export.
private final class PhotoResourceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let manager = PHAssetResourceManager.default()
    private let file: FileHandle
    private let limit: Int64
    private var count: Int64 = 0
    private var lastReport = Date.distantPast
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Int64, Error>?
    private var result: Result<Int64, Error>?

    init(url: URL, limit: Int64) throws {
        self.limit = limit
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw UploadFailure(message: "无法创建原件缓存。") }
        file = try FileHandle(forWritingTo: url)
    }
    func start(_ resource: PHAssetResource, progress: @escaping @Sendable (Int64, Double?) -> Void,
               continuation: CheckedContinuation<Int64, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] fraction in
            guard let self else { return }
            lock.lock()
            defer { lock.unlock() }
            if result == nil { report(progress, cloudFraction: fraction) }
        }
        let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { [self] data in
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            do {
                guard count + Int64(data.count) <= limit else {
                    throw UploadFailure(message: "原件超过剩余缓存预算。请先上传或取消已缓存项目，再重试。")
                }
                try file.write(contentsOf: data)
                count += Int64(data.count)
                report(progress)
                lock.unlock()
            } catch {
                lock.unlock()
                finish(error: error, cancel: true)
            }
        }, completionHandler: { [self] error in
            finish(error: error)
        })
        lock.lock()
        requestID = id
        let ended = result != nil
        lock.unlock()
        if ended { manager.cancelDataRequest(id) }
    }
    // Called with lock held, so the cloud indicator and bytes refer to the same snapshot.
    private func report(_ progress: (Int64, Double?) -> Void, cloudFraction: Double? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.25 else { return }
        lastReport = now
        progress(count, cloudFraction)
    }
    func cancel() { finish(error: CancellationError(), cancel: true) }
    private func finish(error: Error?, cancel: Bool = false) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        var outcome: Result<Int64, Error> = error.map { .failure($0) } ?? .success(count)
        do { try file.close() } catch { outcome = .failure(error) }
        result = outcome
        let pending = continuation
        continuation = nil
        let id = requestID
        lock.unlock()
        if cancel, let id { manager.cancelDataRequest(id) }
        pending?.resume(with: outcome)
    }
}

enum PhotoOriginals {
    struct Selection {
        let resources: [PHAssetResource]
        let edited: Bool

        var sizes: [Int64?] {
            resources.map { resource in
                // dataSize is public on iOS 27. Look up its Obj-C getter so older SDKs can still build.
                guard #available(iOS 27, macOS 27, *) else { return nil }
                let selector = NSSelectorFromString("dataSize")
                guard resource.responds(to: selector),
                      let number = resource.perform(selector)?.takeUnretainedValue() as? NSNumber,
                      number.int64Value > 0 else { return nil }
                return number.int64Value
            }
        }
    }

    static func totalSize(_ sizes: [Int64?]) -> Int64? {
        var total: Int64 = 0
        for size in sizes {
            guard let size else { return nil }
            total += size
        }
        return total
    }

    static func selection(for asset: PHAsset) throws -> Selection {
        let live = asset.mediaSubtypes.contains(.photoLive)
        let video = asset.mediaType == .video
        let resources = PHAssetResource.assetResources(for: asset)
        let choice = try PhotoResourcePolicy.select(types: resources.map { $0.type.rawValue }, live: live, video: video)
        let selected = try choice.types.map { type -> PHAssetResource in
            guard let resource = resources.first(where: { $0.type.rawValue == type }) else { throw UploadFailure(message: "照片资源已变化，请重新选择。") }
            return resource
        }
        return Selection(resources: selected, edited: choice.edited)
    }

    static func prepare(_ item: UploadItem, store: UploadStore,
                        progress: @escaping @Sendable (Int64, Int64?, String) -> Void) async throws -> UploadItem {
        try Task.checkCancellation()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            throw UploadFailure(message: "无法访问所选照片。有限访问时请允许该照片，或在系统设置中调整照片权限后重试。")
        }
        let live = asset.mediaSubtypes.contains(.photoLive)
        let video = asset.mediaType == .video
        let choice = try selection(for: asset)
        let selected = choice.resources
        let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "mp4", "mov"]
        for (index, resource) in selected.enumerated() {
            let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
            guard extensions.contains(ext), !(live && index == 1 && ext != "mov") else {
                throw UploadFailure(message: "家庭站点暂不支持该原件格式：\(ext)。未转换文件。")
            }
        }
        try store.removeFiles(item.id) // Only unconfirmed extraction reaches this method.
        let directory = store.itemDirectory(item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var prepared = item
        prepared.name = selected[0].originalFilename
        prepared.mediaType = live ? "live_photo" : video ? "video" : "photo"
        prepared.resources = []
        prepared.warning = choice.edited ? "仅取得完整尺寸的编辑后副本，字节保持不变，但不是相机未修改原片。" : ""
        var resourceSizes = choice.sizes
        var readBytes: Int64 = 0
        do {
            for (index, resource) in selected.enumerated() {
                try Task.checkCancellation()
                try store.checkSpace()
                let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
                let budget = min(UploadStore.cacheLimit - (try store.cacheBytes()), (free?.int64Value ?? 0) - UploadStore.freeReserve)
                let role = index == 0 ? "original" : "live_video"
                let filename = role + "." + (resource.originalFilename as NSString).pathExtension.lowercased()
                let url = directory.appendingPathComponent(filename)
                let priorBytes = readBytes
                let expected = totalSize(resourceSizes)
                let reading = "正在读取 \(resource.originalFilename)（可能需要从 iCloud 下载）"
                progress(priorBytes, expected, reading)
                let writer = try PhotoResourceWriter(url: url, limit: budget)
                let copied: Int64 = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        writer.start(resource, progress: { bytes, cloudFraction in
                            let totalRead = priorBytes + bytes
                            let message = cloudFraction.map { "iCloud 下载 \($0.formatted(.percent.precision(.fractionLength(0))))" } ?? reading
                            progress(totalRead, expected.flatMap { $0 >= totalRead ? $0 : nil }, message)
                        }, continuation: continuation)
                    }
                } onCancel: { writer.cancel() }
                try Task.checkCancellation()
                readBytes += copied
                resourceSizes[index] = copied
                progress(readBytes, totalSize(resourceSizes), "正在流式校验 \(resource.originalFilename)")
                let digest = try FileIntegrity.fingerprint(url) { try Task.checkCancellation() }
                prepared.resources.append(UploadResource(role: role, filename: resource.originalFilename,
                    mimeType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream",
                    path: filename, size: digest.size, sha256: digest.sha256, crc64: digest.crc64))
            }
            var metadata = try await OriginalMetadata.inspect(prepared.resources, directory: directory, asset: asset, edited: choice.edited)
            prepared.captureDate = metadata["original_taken_at_local"] as? String
            prepared.photoKitDate = asset.creationDate
            if let warning = metadata.removeValue(forKey: "client_warning") as? String {
                prepared.warning += (prepared.warning.isEmpty ? "" : "\n") + warning
            }
            prepared.fields = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            prepared.phase = .ready
            prepared.sourceByteCount = prepared.size
            prepared.message = live ? "图片和 MOV 已完整提取，等待确认。" : "原始字节已缓存，等待确认。"
            return prepared
        } catch {
            try? store.removeFiles(item.id)
            throw error
        }
    }
}

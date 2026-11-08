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
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    init(url: URL, limit: Int64) throws {
        self.limit = limit
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw UploadFailure(message: "无法创建原件缓存。") }
        file = try FileHandle(forWritingTo: url)
    }
    func start(_ resource: PHAssetResource, progress: @escaping @Sendable (Double) -> Void,
               continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = progress
        let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { [self] data in
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            do {
                guard count + Int64(data.count) <= limit else {
                    throw UploadFailure(message: "原件超过剩余缓存预算。请先上传或取消已缓存项目，再重试。")
                }
                try file.write(contentsOf: data)
                count += Int64(data.count)
                lock.unlock()
            } catch {
                lock.unlock()
                finish(.failure(error), cancel: true)
            }
        }, completionHandler: { [self] error in
            if let error { finish(.failure(error)) }
            else { finish(.success(())) }
        })
        lock.lock()
        requestID = id
        let ended = result != nil
        lock.unlock()
        if ended { manager.cancelDataRequest(id) }
    }
    func cancel() { finish(.failure(CancellationError()), cancel: true) }
    private func finish(_ value: Result<Void, Error>, cancel: Bool = false) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        var outcome = value
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
    static func prepare(_ item: UploadItem, store: UploadStore,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> UploadItem {
        try Task.checkCancellation()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            throw UploadFailure(message: "无法访问所选照片。有限访问时请允许该照片，或在系统设置中调整照片权限后重试。")
        }
        let live = asset.mediaSubtypes.contains(.photoLive)
        let video = asset.mediaType == .video
        let resources = PHAssetResource.assetResources(for: asset)
        let choice = try PhotoResourcePolicy.select(types: resources.map { $0.type.rawValue }, live: live, video: video)
        let selected = try choice.types.map { type -> PHAssetResource in
            guard let resource = resources.first(where: { $0.type.rawValue == type }) else { throw UploadFailure(message: "照片资源已变化，请重新选择。") }
            return resource
        }
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
        do {
            for (index, resource) in selected.enumerated() {
                try Task.checkCancellation()
                try store.checkSpace()
                let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
                let budget = min(UploadStore.cacheLimit - (try store.cacheBytes()), (free?.int64Value ?? 0) - UploadStore.freeReserve)
                let role = index == 0 ? "original" : "live_video"
                let filename = role + "." + (resource.originalFilename as NSString).pathExtension.lowercased()
                let url = directory.appendingPathComponent(filename)
                progress(Double(index) / Double(selected.count), "正在准备 \(resource.originalFilename)（可能需要从 iCloud 下载）")
                let writer = try PhotoResourceWriter(url: url, limit: budget)
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        writer.start(resource, progress: { fraction in
                            progress((Double(index) + fraction) / Double(selected.count), "iCloud / 原件准备 \(Int(fraction * 100))%")
                        }, continuation: continuation)
                    }
                    try Task.checkCancellation()
                } onCancel: { writer.cancel() }
                progress(Double(index + 1) / Double(selected.count), "正在流式校验 \(resource.originalFilename)")
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
            prepared.preparationProgress = 1
            prepared.message = live ? "图片和 MOV 已完整提取，等待确认。" : "原始字节已缓存，等待确认。"
            return prepared
        } catch {
            try? store.removeFiles(item.id)
            throw error
        }
    }
}

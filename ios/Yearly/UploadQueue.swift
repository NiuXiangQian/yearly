import SwiftUI
import Photos
import WebKit

@MainActor final class UploadQueue: ObservableObject {
    @Published private(set) var items: [UploadItem] = []
    @Published var error = ""
    @Published private(set) var running = false
    private var store: UploadStore?
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var suspended = true
    private var backgroundResume: Set<UUID> = []
    private var pendingResumes: Set<UUID> = []
    private var site: SiteOrigin?
    private var cookieStore: WKHTTPCookieStore?

    init() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let store = try UploadStore(directory: root.appendingPathComponent("NativeUploads", isDirectory: true))
            items = try store.load()
            self.store = store
            for item in items where item.isTerminal { try? store.removeFiles(item.id) }
        } catch {
            self.error = "无法读取上传队列，已停止写入以保护缓存：\(error.localizedDescription)"
        }
    }
    func configure(site: SiteOrigin, cookieStore: WKHTTPCookieStore) {
        if self.site?.url != site.url { pauseAll() }
        self.site = site
        self.cookieStore = cookieStore
    }
    private func persist() throws {
        guard let store else { throw UploadFailure(message: "队列存储不可用。") }
        do { try store.save(items) }
        catch {
            suspended = true
            worker?.cancel()
            self.error = "无法保存任务状态，上传已暂停：\(error.localizedDescription)"
            throw error
        }
    }
    func add(identifiers: [String], account: UploadAccount) {
        guard let site, store != nil else { return }
        // Fetch individually: PHFetchResult does not promise picker order.
        for identifier in identifiers {
            if items.contains(where: { $0.assetIdentifier == identifier && $0.site == site.url.absoluteString && $0.ownerID == account.id && !$0.isTerminal }) { continue }
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            let resource = asset.flatMap { PHAssetResource.assetResources(for: $0).first }
            var item = UploadItem(assetIdentifier: identifier, site: site.url.absoluteString, ownerID: account.id,
                                  name: resource?.originalFilename ?? "无法访问的照片",
                                  mediaType: asset?.mediaSubtypes.contains(.photoLive) == true ? "live_photo" : asset?.mediaType == .video ? "video" : "photo")
            item.photoKitDate = asset?.creationDate
            items.append(item)
        }
        do { try persist(); suspended = false; start() } catch { }
    }
    func confirm(ids: Set<UUID>, childIDs: [Int], batchName: String, archiveDate: String?) {
        for index in items.indices where ids.contains(items[index].id) && items[index].phase == .ready {
            items[index].childIDs = childIDs.sorted()
            items[index].batchName = String(batchName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
            items[index].archiveDate = archiveDate
            items[index].confirmed = true
            items[index].phase = .queued
            items[index].message = ""
        }
        do { try persist(); suspended = false; start() } catch { }
    }
    func resume(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].isTerminal,
              [.paused, .failed].contains(items[i].phase) else { return }
        if activeID == id && worker != nil {
            pendingResumes.insert(id)
            suspended = false
            return
        }
        items[i].phase = items[i].resources.isEmpty ? .selected : items[i].confirmed ? .queued : .ready
        items[i].message = ""
        do { try persist(); suspended = false; start() } catch { }
    }
    func resumeAll() {
        guard let site else { return }
        for i in items.indices where items[i].site == site.url.absoluteString && items[i].phase == .paused {
            if activeID == items[i].id && worker != nil {
                pendingResumes.insert(items[i].id)
                continue
            }
            items[i].phase = items[i].resources.isEmpty ? .selected : items[i].confirmed ? .queued : .ready
        }
        do { try persist(); suspended = false; start() } catch { }
    }
    func pause(_ id: UUID) {
        pendingResumes.remove(id)
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].isTerminal else { return }
        items[i].phase = .paused
        if activeID == id { worker?.cancel() }
        do { try persist() } catch { }
    }
    func pauseAll() {
        pendingResumes.removeAll()
        suspended = true
        worker?.cancel()
        for i in items.indices where [.selected, .preparing, .queued, .uploading].contains(items[i].phase) { items[i].phase = .paused }
        if store != nil { do { try persist() } catch { } }
    }
    func cancel(_ id: UUID) {
        pendingResumes.remove(id)
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].isTerminal else { return }
        items[i].phase = .cancelled
        items[i].message = "已取消本机任务；未完成的服务端任务按现有 7 天策略清理。"
        if activeID == id { worker?.cancel() }
        do {
            try persist() // Persist intent before removing bytes, including when the app is killed.
            if activeID != id { try store?.removeFiles(id) }
        } catch { self.error = error.localizedDescription }
    }
    func enteredBackground() {
        backgroundResume = Set(items.filter { [.selected, .preparing, .queued, .uploading].contains($0.phase) }.map(\.id))
        pauseAll()
    }
    func enteredForeground() {
        guard !backgroundResume.isEmpty else { return }
        let ids = backgroundResume
        backgroundResume = []
        for id in ids { resume(id) }
    }
    private func start() {
        guard worker == nil, !suspended, let site, let cookieStore, store != nil else { return }
        running = true
        worker = Task {
            await run(site: site, cookieStore: cookieStore)
            activeID = nil
            worker = nil
            running = false
            // A per-item cancellation must not discard the other items in this batch.
            if !suspended && items.contains(where: { $0.site == self.site?.url.absoluteString && [.selected, .queued].contains($0.phase) }) { start() }
        }
    }
    private func run(site: SiteOrigin, cookieStore: WKHTTPCookieStore) async {
        guard let store else { return }
        while !suspended && !Task.isCancelled {
            guard let index = items.firstIndex(where: { $0.site == site.url.absoluteString && [.selected, .queued].contains($0.phase) }) else { return }
            let id = items[index].id
            activeID = id
            do {
                if items[index].phase == .selected {
                    items[index].phase = .preparing
                    try persist()
                    let source = items[index]
                    let extraction = Task.detached(priority: .utility) {
                        try await PhotoOriginals.prepare(source, store: store) { [weak self] progress, message in
                            Task { @MainActor in
                                guard let self, let i = self.items.firstIndex(where: { $0.id == id }), self.items[i].phase == .preparing else { return }
                                self.items[i].preparationProgress = progress
                                self.items[i].message = message
                            }
                        }
                    }
                    let prepared = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                    try Task.checkCancellation()
                    items[index] = prepared
                    try persist()
                } else {
                    let service = UploadAPI(site: site, cookieStore: cookieStore, ownerID: items[index].ownerID)
                    items[index].phase = .uploading
                    items[index].message = "正在核对原件与上传任务…"
                    try persist()
                    // Rehash disk bytes before every resume; a corrupted cache must never masquerade as an original.
                    for resource in items[index].resources where !resource.complete {
                        let url = try store.file(resource, itemID: id)
                        let hashing = Task.detached(priority: .utility) { try FileIntegrity.fingerprint(url) { try Task.checkCancellation() } }
                        let hash = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
                        guard hash.sha256 == resource.sha256 && hash.crc64 == resource.crc64 && hash.size == resource.size else {
                            throw UploadFailure(message: "本机原件校验不符，未上传；请取消后重新从相册选择。")
                        }
                    }
                    try Task.checkCancellation()
                    if items[index].mediaID == nil {
                        items[index].requestStarted = true
                        let body = try items[index].body()
                        try persist() // The UUID and exact payload must survive a lost create response.
                        let creation = try await MultipartUploader.retry { try await service.create(body: body, key: id) }
                        if creation.duplicate != true {
                            guard creation.tasks.count == items[index].resources.count else { throw UploadFailure(message: "服务端返回的资源任务不完整。") }
                            for r in items[index].resources.indices {
                                let resource = items[index].resources[r]
                                guard let task = creation.tasks.first(where: { $0.file_role == resource.role }), task.sha256 == resource.sha256, task.file_size == resource.size else { throw UploadFailure(message: "服务端资源任务不匹配。") }
                                items[index].resources[r].task = task
                            }
                        }
                        items[index].mediaID = creation.media_id
                        items[index].duplicate = creation.duplicate == true
                        try persist()
                    }
                    if !items[index].duplicate {
                        for r in items[index].resources.indices {
                            try Task.checkCancellation()
                            let resource = items[index].resources[r]
                            if resource.complete { continue }
                            items[index].message = resource.role == "live_video" ? "正在上传 Live Photo MOV" : "正在上传原件"
                            try await MultipartUploader.upload(resource, file: store.file(resource, itemID: id), service: service) { bytes, complete in
                                self.items[index].resources[r].uploadedBytes = bytes
                                self.items[index].resources[r].complete = complete
                                if bytes == resource.size && !complete { self.items[index].message = "分片已传完，等待服务端完整性校验…" }
                                try self.persist()
                            }
                        }
                        guard items[index].resources.allSatisfy(\.complete) else { throw UploadFailure(message: "仍有未通过完整性校验的资源。") }
                    }
                    // A successful server completion cannot be undone by cancelling the local UI.
                    if items[index].phase != .cancelled {
                        items[index].phase = .complete
                        items[index].message = items[index].duplicate ? "已存在：沿用原记录并合并所选人物关联。" : "全部资源已通过服务端校验，可返回时间线查看。"
                    }
                    try persist()
                    try store.removeFiles(id)
                }
            } catch {
                if items[index].phase == .cancelled {
                    try? store.removeFiles(id)
                } else if Task.isCancelled || error is CancellationError || items[index].phase == .paused {
                    items[index].phase = .paused
                    items[index].message = "已安全暂停；继续时读取服务端分片状态。"
                } else {
                    items[index].phase = .failed
                    // Never expose signed URLs from URLSession NSError descriptions.
                    items[index].message = error is URLError ? "网络中断，原件与已完成分片已保留，请重试。" : error.localizedDescription
                }
                if let http = error as? UploadHTTPError, !http.isOSS, [401, 403].contains(http.status) {
                    self.error = http.localizedDescription
                    pauseAll()
                }
                do { try persist() } catch { return }
            }
            if pendingResumes.remove(id) != nil && items[index].phase == .paused {
                items[index].phase = items[index].resources.isEmpty ? .selected : items[index].confirmed ? .queued : .ready
                do { try persist() } catch { return }
            }
            activeID = nil
        }
    }
}

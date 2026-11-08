import SwiftUI
import Photos

@MainActor final class UploadQueue: ObservableObject {
    struct Transfer {
        let itemID: UUID
        let inFlightBytes: Int64
        let bytesPerSecond: Double
        let sampledAt: Date
    }
    struct Preparation {
        let itemID: UUID
        let bytesRead: Int64
        let bytesPerSecond: Double
        let sampledAt: Date
    }

    @Published private(set) var items: [UploadItem] = []
    @Published var error = ""
    @Published private(set) var duplicateNotice = ""
    private var duplicateNames: [String] = []
    @Published private(set) var running = false
    @Published private(set) var transfer: Transfer?
    @Published private(set) var preparation: Preparation?
    @Published private(set) var uploadGroup: Set<UUID> = []
    private var store: UploadStore?
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var suspended = true
    private var backgroundResume: Set<UUID> = []
    private var pendingResumes: Set<UUID> = []
    private var site: SiteOrigin?
    private weak var session: NativeSession?
    private var configuredOwnerID: Int?

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
    func configure(session: NativeSession) {
        if self.session !== session || configuredOwnerID != session.account?.id {
            pauseAll()
            uploadGroup = []
            duplicateNotice = ""; duplicateNames = []
        }
        configuredOwnerID = session.account?.id
        self.site = session.site
        self.session = session
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
    private func noteDuplicate(_ name: String) {
        duplicateNames.append(name)
        let names = duplicateNames.prefix(5).joined(separator: "、")
        duplicateNotice = "发现 \(duplicateNames.count) 项重复文件，已阻止重复上传。\n\(names)\(duplicateNames.count > 5 ? " 等" : "")\n已存在的原件会跳过；队列中的原件请继续原任务。其他文件继续上传。"
    }
    func add(identifiers: [String], account: UploadAccount) {
        guard let site, store != nil, session?.account?.id == account.id, session?.canEdit == true else { return }
        duplicateNotice = ""; duplicateNames = []
        // Fetch individually: PHFetchResult does not promise picker order.
        for identifier in identifiers {
            if let existing = items.first(where: { $0.assetIdentifier == identifier && $0.site == site.url.absoluteString && $0.ownerID == account.id && !$0.isTerminal }) {
                noteDuplicate(existing.name)
                continue
            }
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            let selection = asset.flatMap { try? PhotoOriginals.selection(for: $0) }
            let resource = selection?.resources.first
            var item = UploadItem(assetIdentifier: identifier, site: site.url.absoluteString, ownerID: account.id,
                                  name: resource?.originalFilename ?? "无法访问的照片",
                                  mediaType: asset?.mediaSubtypes.contains(.photoLive) == true ? "live_photo" : asset?.mediaType == .video ? "video" : "photo")
            item.photoKitDate = asset?.creationDate
            item.sourceByteCount = selection.flatMap { PhotoOriginals.totalSize($0.sizes) }
            items.append(item)
        }
        do { try persist(); suspended = false; start() } catch { }
    }
    func confirm(ids: Set<UUID>, childIDs: [Int], batchName: String, archiveDate: String?) {
        guard session?.canEdit == true else { return }
        beginBatchIfNeeded()
        var skipped: [UUID] = []
        for index in items.indices where ids.contains(items[index].id) && items[index].phase == .ready && items[index].ownerID == session?.account?.id && items[index].site == site?.url.absoluteString {
            uploadGroup.insert(items[index].id)
            if items.contains(where: { $0.id != items[index].id && $0.confirmed && !$0.isTerminal && $0.sameOriginals(as: items[index]) }) {
                items[index].phase = .skipped
                items[index].duplicate = true
                items[index].message = "相同原件已在本机上传队列中，已跳过，不会重复上传。"
                skipped.append(items[index].id)
                noteDuplicate(items[index].name)
                continue
            }
            items[index].childIDs = childIDs.sorted()
            items[index].batchName = String(batchName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
            items[index].archiveDate = archiveDate ?? items[index].albumArchiveDay()
            items[index].confirmed = true
            items[index].phase = .queued
            items[index].message = ""
        }
        do { try persist(); for id in skipped { try store?.removeFiles(id) }; suspended = false; start() } catch { }
    }
    func resume(_ id: UUID) {
        resume(phases: [.paused, .failed], id: id)
    }

    func resumeAll() {
        resume(phases: [.paused])
    }

    func retryFailed() {
        resume(phases: [.failed])
    }

    private func resume(phases: Set<UploadPhase>, id: UUID? = nil) {
        guard let site, let session, session.canEdit, let ownerID = session.account?.id else { return }
        let matches = items.indices.filter { index in
            let item = items[index]
            return item.site == site.url.absoluteString && item.ownerID == ownerID &&
                phases.contains(item.phase) && (id == nil || item.id == id)
        }
        guard !matches.isEmpty else { return }
        let uploads = matches.filter { items[$0].confirmed }.map { items[$0].id }
        if !uploads.isEmpty {
            beginBatchIfNeeded()
            uploadGroup.formUnion(uploads)
        }
        for i in matches {
            if activeID == items[i].id && worker != nil {
                pendingResumes.insert(items[i].id)
                continue
            }
            requeue(at: i)
        }
        do { try persist(); suspended = false; start() } catch { }
    }

    private func requeue(at index: Int) {
        let item = items[index]
        items[index].phase = item.resources.isEmpty ? .selected : item.confirmed ? .queued : .ready
        items[index].message = ""
    }
    private func beginBatchIfNeeded() {
        if !items.contains(where: { uploadGroup.contains($0.id) && ($0.phase.canPause || $0.phase == .paused) }) {
            uploadGroup = []
        }
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
        transfer = nil
        preparation = nil
        for i in items.indices where items[i].phase.canPause { items[i].phase = .paused }
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
        backgroundResume = Set(items.filter { $0.phase.canPause }.map(\.id))
        pauseAll()
    }
    func enteredForeground() {
        guard !backgroundResume.isEmpty else { return }
        let ids = backgroundResume
        backgroundResume = []
        for id in ids { resume(id) }
    }
    private func start() {
        guard worker == nil, !suspended, let site, let session, session.canEdit, store != nil else { return }
        running = true
        worker = Task {
            await run(site: site, session: session)
            activeID = nil
            preparation = nil
            worker = nil
            running = false
            // A per-item cancellation must not discard the other items in this batch.
            if !suspended && items.contains(where: { $0.site == self.site?.url.absoluteString && $0.ownerID == self.session?.account?.id && [.selected, .queued].contains($0.phase) }) { start() }
        }
    }
    private func run(site: SiteOrigin, session: NativeSession) async {
        guard let store else { return }
        while !suspended && !Task.isCancelled {
            guard let index = items.firstIndex(where: { $0.site == site.url.absoluteString && $0.ownerID == session.account?.id && [.selected, .queued].contains($0.phase) }) else { return }
            let id = items[index].id
            activeID = id
            do {
                if items[index].phase == .selected {
                    let started = Date()
                    items[index].phase = .preparing
                    try persist()
                    let source = items[index]
                    let extraction = Task.detached(priority: .utility) {
                        try await PhotoOriginals.prepare(source, store: store) { [weak self] bytes, total, message in
                            let sampledAt = Date()
                            Task { @MainActor in
                                guard let self, self.activeID == id, self.items[index].phase == .preparing else { return }
                                if let previous = self.preparation, sampledAt < previous.sampledAt { return }
                                if self.items[index].sourceByteCount != total { self.items[index].sourceByteCount = total }
                                if self.items[index].message != message { self.items[index].message = message }
                                let elapsed = max(0.25, sampledAt.timeIntervalSince(started))
                                self.preparation = Preparation(itemID: id, bytesRead: bytes, bytesPerSecond: Double(bytes) / elapsed, sampledAt: sampledAt)
                            }
                        }
                    }
                    let prepared = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                    try Task.checkCancellation()
                    items[index] = prepared
                    try persist()
                } else {
                    uploadGroup.insert(id)
                    let service = session.uploadAPI(ownerID: items[index].ownerID)
                    service.onPartProgress = { [weak self] bytes, rate in
                        guard let self, self.activeID == id, self.items[index].phase == .uploading else { return }
                        if rate == 0 {
                            self.transfer = nil
                            return
                        }
                        let now = Date()
                        if let previous = self.transfer, now.timeIntervalSince(previous.sampledAt) < 0.25 { return }
                        self.transfer = Transfer(itemID: id, inFlightBytes: bytes, bytesPerSecond: rate, sampledAt: now)
                    }
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
                        // Pending items from earlier releases can use this default before their first request.
                        // An idempotent retry must send exactly the payload already persisted.
                        if !items[index].requestStarted && items[index].archiveDate == nil {
                            items[index].archiveDate = items[index].albumArchiveDay()
                        }
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
                            items[index].message = items[index].mediaType == "live_photo" ? "正在上传实况原件" : "正在上传原件"
                            try await MultipartUploader.upload(resource, file: store.file(resource, itemID: id), service: service) { bytes, complete in
                                self.items[index].resources[r].uploadedBytes = bytes
                                self.items[index].resources[r].complete = complete
                                if let previous = self.transfer {
                                    self.transfer = Transfer(itemID: id, inFlightBytes: 0, bytesPerSecond: previous.bytesPerSecond, sampledAt: previous.sampledAt)
                                }
                                if bytes == resource.size && !complete { self.items[index].message = "分片已传完，等待服务端完整性校验…" }
                                try self.persist()
                            }
                        }
                        guard items[index].resources.allSatisfy(\.complete) else { throw UploadFailure(message: "仍有未通过完整性校验的资源。") }
                    }
                    // A successful server completion cannot be undone by cancelling the local UI.
                    if items[index].phase != .cancelled {
                        items[index].phase = items[index].duplicate ? .skipped : .complete
                        items[index].message = items[index].duplicate ? "重复原件已跳过，没有再次上传；沿用原记录并合并所选人物关联。" : "全部资源已通过服务端校验，可返回时间线查看。"
                    }
                    try persist()
                    if items[index].duplicate { noteDuplicate(items[index].name) }
                    try? store.removeFiles(id)
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
                if let http = error as? UploadHTTPError, !http.isOSS, http.status == 409,
                   http.detail?.contains("相同原件已有未完成上传") == true { noteDuplicate(items[index].name) }
                if let http = error as? UploadHTTPError, !http.isOSS, [401, 403].contains(http.status) {
                    self.error = http.localizedDescription
                    pauseAll()
                }
                do { try persist() } catch { return }
            }
            if pendingResumes.remove(id) != nil && [.paused, .failed].contains(items[index].phase) {
                requeue(at: index)
                do { try persist() } catch { return }
            }
            activeID = nil
            preparation = nil
            transfer = nil
        }
    }
}

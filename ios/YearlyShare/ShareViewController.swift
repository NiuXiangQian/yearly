import SwiftUI
import UniformTypeIdentifiers
import ImageIO

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let host = UIHostingController(rootView: ShareUploadView(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

struct ShareUploadView: View {
    let providers: [NSItemProvider]
    let close: () -> Void
    @StateObject private var queue = UploadQueue()
    @State private var session: NativeSession?
    @State private var profiles: [UploadProfile] = []
    @State private var children: Set<Int> = []
    @State private var visibleIDs: Set<UUID> = []
    @State private var importedIDs: Set<UUID> = []
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var loading = false
    @State private var started = false
    @State private var loaded = false
    @State private var status = "正在读取照片…"
    @State private var message = ""
    @State private var useArchiveDate = false
    @State private var archiveDate = Date()

    init(providers: [NSItemProvider], close: @escaping () -> Void) {
        self.providers = providers
        self.close = close
    }
    private var items: [UploadItem] { queue.items.filter { visibleIDs.contains($0.id) && $0.phase != .cancelled } }
    private var ready: [UploadItem] { items.filter { $0.phase == .ready } }
    private var done: Bool { !items.isEmpty && items.allSatisfy(\.isTerminal) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("从相册上传", systemImage: "photo.on.rectangle.angled")
                        .font(.title3.weight(.semibold))
                    if let session, let account = session.account {
                        Text("\(account.displayName) · \(session.site.url.host ?? "")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if loading { ProgressView(status) }
                    if !message.isEmpty { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                    if !queue.error.isEmpty { Text(queue.error).foregroundStyle(.red) }
                    if !queue.duplicateNotice.isEmpty { Text(queue.duplicateNotice).font(.footnote) }
                    if !loaded && !loading {
                        Button("重新读取") { Task { await load() } }
                    }
                } footer: {
                    Text("上传相册实际分享的图片版本。视频与完整实况照片请在 App 内导入。")
                }
                if !items.isEmpty {
                    Section("照片（\(items.count)）") {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                if let thumbnail = thumbnails[item.id] {
                                    Image(uiImage: thumbnail).resizable().scaledToFill()
                                        .frame(width: 56, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    Image(systemName: "photo").frame(width: 56, height: 56).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.subheadline).lineLimit(2)
                                    Text(item.phase.label).font(.caption).foregroundStyle(item.phase == .failed ? .red : .secondary)
                                    if item.phase == .uploading {
                                        let inFlight = queue.transfer.flatMap { $0.itemID == item.id ? $0.inFlightBytes : nil } ?? 0
                                        ProgressView(value: Double(min(item.size, item.uploadedBytes + inFlight)), total: Double(max(1, item.size)))
                                    }
                                    if !item.warning.isEmpty && !item.confirmed { Text(item.warning).font(.caption).foregroundStyle(.secondary) }
                                    if !item.message.isEmpty { Text(item.message).font(.caption).foregroundStyle(item.phase == .failed ? .red : .secondary) }
                                    if [.failed, .paused].contains(item.phase) {
                                        Button(item.confirmed ? "继续上传" : "继续准备") { queue.resume(item.id) }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                Spacer(minLength: 0)
                                if !item.isTerminal {
                                    Button { queue.cancel(item.id) } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                                        .buttonStyle(.borderless).accessibilityLabel("\(item.confirmed ? "取消上传" : "移除") \(item.name)")
                                }
                            }
                        }
                    }
                }
                if !ready.isEmpty {
                    Section {
                        if profiles.isEmpty { Text("未关联人物，上传到家庭时间线。").foregroundStyle(.secondary) }
                        ForEach(profiles) { profile in
                            Toggle(profile.label, isOn: Binding(get: { children.contains(profile.id) }, set: {
                                if $0 { children.insert(profile.id) } else { children.remove(profile.id) }
                            }))
                        }
                    } header: { Text("关联人物与宠物") } footer: { Text("可以多选；不选则仅收录到家庭时间线。") }
                    .disabled(queue.running || loading)
                    Section {
                        Toggle("指定归档日期", isOn: $useArchiveDate)
                        if useArchiveDate { DatePicker("归档日期", selection: $archiveDate, displayedComponents: .date) }
                    } footer: { Text("未指定时优先采用图片拍摄日期；没有拍摄日期则按上传日期归档。") }
                    .disabled(queue.running || loading)
                }
                if done { Section { Label("上传完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
            }
            .safeAreaInset(edge: .bottom) {
                if !ready.isEmpty {
                    VStack(spacing: 8) {
                        Button { upload() } label: {
                            Label("上传 \(ready.count) 张照片", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NativeActionStyle(kind: .primary))
                        .disabled(loading || queue.running || session?.canEdit != true)
                        Text("保持窗口打开。关闭或切到后台会暂停，下次分享时可继续。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial)
                }
            }
            .navigationTitle("上传到 yearly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "完成" : queue.running ? "稍后继续" : "关闭") {
                        queue.pauseAll()
                        for item in items where importedIDs.contains(item.id) && !item.confirmed { queue.cancel(item.id) }
                        close()
                    }
                }
            }
            .tint(NativeTheme.accent)
        }
        .task { if !started { started = true; await load() } }
        .onDisappear { queue.pauseAll() }
        .onReceive(NotificationCenter.default.publisher(for: .NSExtensionHostDidEnterBackground)) { _ in queue.enteredBackground() }
        .onReceive(NotificationCenter.default.publisher(for: .NSExtensionHostDidBecomeActive)) { _ in queue.enteredForeground() }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        loading = true
        message = ""
        defer { loading = false }
        do {
            guard let site = try ShareDestinationStore().read() else {
                throw UploadFailure(message: "请先打开新版 yearly，设置站点并登录，然后回到相册分享照片。")
            }
            let session = NativeSession(site: site)
            self.session = session
            await session.restore()
            guard let account = session.account else {
                throw UploadFailure(message: session.error.isEmpty ? "请先在 yearly 登录，然后重新分享照片。" : session.error)
            }
            guard session.canEdit else { throw UploadFailure(message: "当前为只读账号，请在 yearly 切换到有上传权限的账号后重试。") }
            profiles = try await session.get("/children", refresh: true)
            children = UploadProfilePreferences(site: session.site, ownerID: account.id).restore(validIDs: Set(profiles.map(\.id)))
            queue.configure(session: session)
            visibleIDs.formUnion(queue.items.filter { $0.site == session.site.url.absoluteString && $0.ownerID == account.id && !$0.isTerminal }.map(\.id))
            guard !providers.isEmpty, providers.count <= 20 else {
                throw UploadFailure(message: "请从相册分享 1 至 20 张照片。")
            }
            var failures: [String] = []
            for (index, provider) in providers.enumerated() {
                try Task.checkCancellation()
                status = "正在读取第 \(index + 1) / \(providers.count) 张照片…"
                do {
                    if provider.hasItemConformingToTypeIdentifier("com.apple.live-photo") {
                        throw UploadFailure(message: "实况照片请在 App 内导入，以保留图片与动态原片。")
                    }
                    guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                        throw UploadFailure(message: "此项目不是支持的图片，请在 App 内导入。")
                    }
                    // Provider URLs expire when the callback returns; copy before resuming.
                    let suggestedName = provider.suggestedName
                    let imported: (URL, String) = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                            do {
                                if let error { throw error }
                                guard let url else { throw UploadFailure(message: "相册未提供可读取的图片，请下载 iCloud 照片后重试。") }
                                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                try FileManager.default.copyItem(at: url, to: copy)
                                continuation.resume(returning: (copy, suggestedName ?? url.lastPathComponent))
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    let (file, name) = imported
                    defer { try? FileManager.default.removeItem(at: file) }
                    let id = try await queue.addSharedPhoto(file: file, name: name)
                    visibleIDs.insert(id)
                    importedIDs.insert(id)
                    let thumbnail = await Task.detached(priority: .utility) { () -> CGImage? in
                        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 168,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                        ] as CFDictionary)
                    }.value
                    if let thumbnail { thumbnails[id] = UIImage(cgImage: thumbnail) }
                } catch {
                    if error is CancellationError { throw error }
                    failures.append("第 \(index + 1) 项：\(friendly(error))")
                }
            }
            message = failures.joined(separator: "\n")
            loaded = true
        } catch { message = friendly(error) }
    }

    @MainActor private func upload() {
        guard let session, let account = session.account else { return }
        UploadProfilePreferences(site: session.site, ownerID: account.id).save(children)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        queue.confirm(ids: Set(ready.map(\.id)), childIDs: children.sorted(), batchName: "",
                      archiveDate: useArchiveDate ? formatter.string(from: archiveDate) : nil)
    }
}

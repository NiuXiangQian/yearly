import SwiftUI
import PhotosUI

struct NativeUploadView: View {
    @ObservedObject var queue: UploadQueue
    @ObservedObject var session: NativeSession
    private var site: SiteOrigin { session.site }
    let onTimeline: () -> Void
    @State private var account: UploadAccount?
    @State private var profiles: [UploadProfile] = []
    @State private var children: Set<Int> = []
    @State private var batchName = ""
    @State private var useArchiveDate = false
    @State private var archiveDate = Date()
    @State private var showPicker = false
    @State private var confirming = false
    @State private var excluded: Set<UUID> = []
    @State private var message = ""
    @State private var showingDuplicate = false

    private var items: [UploadItem] { queue.items.filter { $0.site == site.url.absoluteString && $0.ownerID == session.account?.id } }
    private var ready: [UploadItem] { items.filter { $0.phase == .ready && !excluded.contains($0.id) } }
    private var totalProgress: Double {
        let confirmed = items.filter { $0.confirmed && !$0.duplicate && $0.phase != .cancelled }
        let bytes = confirmed.reduce(Int64(0)) { $0 + $1.size }
        return bytes == 0 ? 0 : confirmed.reduce(0.0) { $0 + $1.progress * Double($1.size) } / Double(bytes)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !queue.duplicateNotice.isEmpty {
                        Label("发现重复文件", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(queue.duplicateNotice).font(.callout)
                        Button("查看重复提醒") { showingDuplicate = true }
                            .alert("发现重复文件", isPresented: $showingDuplicate) {
                                Button("知道了", role: .cancel) { }
                            } message: { Text(queue.duplicateNotice) }
                    }
                    Button { Task { await choosePhotos() } } label: { Label("从系统相册选择照片与视频", systemImage: "photo.on.rectangle.angled") }
                        .disabled(account == nil)
                    Text("按点选顺序导入；Live Photo 自动包含图片与 MOV。仅访问你选择并授权的项目。")
                        .font(.caption).foregroundStyle(.secondary)
                    if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
                        Text("当前为有限访问。若某项无法读取，请在系统照片权限中将它加入允许列表后重试。")
                            .font(.caption).foregroundStyle(.orange)
                        Button("管理允许访问的照片") { presentLimitedPicker() }
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
                    if !queue.error.isEmpty { Text(queue.error).font(.caption).foregroundStyle(.red) }
                    if account == nil { Button("刷新登录状态") { Task { await loadAccount() } } }
                } header: { Text("原生无损导入") }
                Section {
                    TextField("这批回忆的名字（可留空）", text: $batchName)
                    Toggle("设置本批归档日期", isOn: $useArchiveDate)
                    if useArchiveDate { DatePicker("归档日期", selection: $archiveDate, displayedComponents: .date) }
                    Text("归档日期独立于原始拍摄时间；留空按每份原件的拍摄日期归档。未选择人物时保留为家庭时光。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(profiles) { profile in
                        Toggle(profile.label, isOn: Binding(get: { children.contains(profile.id) }, set: { if $0 { children.insert(profile.id) } else { children.remove(profile.id) } }))
                    }
                } header: { Text("上传确认 · 人物、孩子与宠物可多选") }
                Section {
                    ProgressView(value: totalProgress)
                    Text("\(items.filter { $0.phase == .complete }.count) 成功 · \(items.filter { $0.phase == .skipped }.count) 重复已跳过 · \(items.filter { $0.phase == .failed }.count) 失败 · \(items.count) 项")
                    Text("照片 \(items.filter { $0.mediaType == "photo" }.count) · Live Photo \(items.filter { $0.mediaType == "live_photo" }.count) · 视频 \(items.filter { $0.mediaType == "video" }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("全部暂停") { queue.pauseAll() }
                        Spacer()
                        Button("继续暂停任务") { queue.resumeAll() }.disabled(account == nil)
                    }
                    Button("确认上传所选 \(ready.count) 项") { confirming = true }
                        .disabled(ready.isEmpty || account == nil)
                    Text("原件先提取到本机，显示准确大小后再确认上传。缓存上限 8 GiB，预留 512 MiB；达到上限时先上传已准备的项目，再重试其余项目。进入后台会暂停，回到前台续传；强制退出后请点继续。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("上传任务") }
                ForEach(items) { item in
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            AssetThumbnail(identifier: item.assetIdentifier)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.subheadline.bold()).lineLimit(2)
                                if item.mediaType == "live_photo" { Label("LIVE · \(item.resources.count == 2 ? "双资源已提取" : "等待完整双资源")", systemImage: "livephoto").font(.caption) }
                                Text(item.resources.isEmpty ? "大小：提取后显示" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption)
                                Text("拍摄：\(item.captureDate ?? "未知")").font(.caption)
                                if item.captureDate == nil, let date = item.photoKitDate {
                                    Text("PhotoKit 参考：\(date.formatted(date: .numeric, time: .shortened))（不代替原始时间）")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if item.phase == .ready {
                            Toggle("选择此项上传", isOn: Binding(get: { !excluded.contains(item.id) }, set: { if $0 { excluded.remove(item.id) } else { excluded.insert(item.id) } }))
                        }
                        if !item.warning.isEmpty { Text(item.warning).font(.caption).foregroundStyle(.orange) }
                        Text(item.phase.label).font(.caption.bold())
                        if item.phase == .preparing { ProgressView(value: item.preparationProgress) }
                        if item.confirmed { ProgressView(value: item.progress) }
                        ForEach(item.resources, id: \.role) { resource in
                            Text("\(resource.role == "live_video" ? "MOV" : "原件") · \(resource.filename) · \(ByteCountFormatter.string(fromByteCount: resource.size, countStyle: .file)) · \(resource.complete ? "已校验" : "\(Int(Double(resource.uploadedBytes) / Double(max(resource.size, 1)) * 100))%")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if !item.message.isEmpty { Text(item.message).font(.caption).foregroundStyle(item.phase == .failed ? .red : .secondary) }
                        if !item.isTerminal {
                            HStack {
                                if [.paused, .failed].contains(item.phase) {
                                    Button(item.phase == .failed ? "重试" : "继续") { queue.resume(item.id) }.disabled(account == nil)
                                } else if item.phase != .ready {
                                    Button("暂停") { queue.pause(item.id) }
                                }
                                Spacer()
                                Button("取消", role: .destructive) { queue.cancel(item.id) }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Button("查看家庭时间线") { onTimeline() }
                }
            }
            .navigationTitle("珍藏原片")
            .onChange(of: queue.duplicateNotice.isEmpty) { empty in
                if !empty { showingDuplicate = true }
            }
            .task { queue.configure(session: session); await loadAccount() }
            .sheet(isPresented: $showPicker) {
                NativePhotoPicker { identifiers, unavailable in
                    showPicker = false
                    if unavailable > 0 { message = "\(unavailable) 项未交付可访问的照片标识，请调整图库权限后重新选择。" }
                    if let account { queue.add(identifiers: identifiers, account: account) }
                }
            }
            .alert("确认珍藏所选原件", isPresented: $confirming) {
                Button("确认上传") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"
                    queue.confirm(ids: Set(ready.map(\.id)), childIDs: Array(children), batchName: batchName,
                                  archiveDate: useArchiveDate ? formatter.string(from: archiveDate) : nil)
                }
                Button("返回检查", role: .cancel) { }
            } message: {
                Text("\(ready.count) 项，\(ByteCountFormatter.string(fromByteCount: ready.reduce(0) { $0 + $1.size }, countStyle: .file))。\(useArchiveDate ? "全部归档到所选日期，保留原始拍摄时间。" : "按原始拍摄日期归档；没有可靠日期的保持未知。")\(ready.contains { !$0.warning.isEmpty } ? "部分项目含原件或元数据提示，请确认已阅读每项说明。" : "")")
            }
        }
    }
    private func loadAccount() async {
        do {
            let api = session.uploadAPI()
            let current = try await api.account()
            let loaded = try await api.profiles()
            account = current
            profiles = loaded
            message = ""
        } catch {
            account = nil
            message = error is URLError ? "无法连接家庭站点，请检查网络。" : error.localizedDescription
        }
    }
    private func choosePhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            message = "读取未修改原件需要照片访问权限。请在设置 → Yearly → 照片中允许访问所选照片。"
            return
        }
        showPicker = true
    }
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
}

private struct NativePhotoPicker: UIViewControllerRepresentable {
    let onFinish: ([String], Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([String], Int) -> Void
        init(onFinish: @escaping ([String], Int) -> Void) { self.onFinish = onFinish }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let identifiers = results.compactMap(\.assetIdentifier)
            onFinish(identifiers, results.count - identifiers.count)
        }
    }
}

private struct AssetThumbnail: View {
    let identifier: String
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.secondarySystemBackground)) }
        }
        .frame(width: 64, height: 64).clipped().cornerRadius(8)
        .onAppear {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 128, height: 128), contentMode: .aspectFill, options: options) { value, _ in
                Task { @MainActor in image = value }
            }
        }
        .onDisappear {
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            image = nil
        }
    }
}

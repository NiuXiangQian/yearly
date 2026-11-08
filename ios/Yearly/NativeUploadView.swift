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
    @State private var loadingAccount = false
    @State private var openingPicker = false
    @State private var hasLoaded = false
    @State private var showingPeople = false
    @State private var profileSearch = ""
    @State private var showFinished = false
    @State private var confirmingIDs: Set<UUID> = []
    @State private var cancelling: UploadItem?
    private var chosenNames: String {
        let names = profiles.filter { children.contains($0.id) }.map { $0.nickname.isEmpty ? $0.name : $0.nickname }
        return names.isEmpty ? "仅家庭时光" : names.joined(separator: "、")
    }
    private var confirmationItems: [UploadItem] { items.filter { confirmingIDs.contains($0.id) } }
    private var visibleItems: [UploadItem] { showFinished ? items : items.filter { !$0.isTerminal } }

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
                        .disabled(account == nil || openingPicker)
                    if loadingAccount || openingPicker { ProgressView(openingPicker ? "正在打开系统相册…" : "正在读取人物与登录状态…") }
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
                    Button { showingPeople = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("关联人物与宠物", systemImage: "person.2")
                                Text(chosenNames).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                Text("自动记住选择，下次上传无需重选").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(!hasLoaded || account == nil)

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
                    }.buttonStyle(.borderless)
                    Toggle("显示已结束记录（\(items.filter { $0.isTerminal }.count) 项）", isOn: $showFinished)
                    Text("原件先提取到本机，显示准确大小后再确认上传。缓存上限 8 GiB，预留 512 MiB；达到上限时先上传已准备的项目，再重试其余项目。进入后台会暂停，回到前台续传；强制退出后请点继续。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("上传任务") }
                ForEach(visibleItems) { item in
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
                                Button("取消", role: .destructive) { cancelling = item }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    Button("查看家庭时间线") { onTimeline() }
                }
            }
            .navigationTitle("珍藏原片")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { Task { await choosePhotos() } } label: { Label("选照片", systemImage: "plus") }
                        .buttonStyle(.bordered).disabled(account == nil || openingPicker)
                    Button {
                        confirmingIDs = Set(ready.map(\.id)); confirming = true
                    } label: {
                        Text(ready.isEmpty ? (visibleItems.isEmpty ? "选择照片后上传" : "等待原件准备") : "上传所选 \(ready.count) 项").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(ready.isEmpty || account == nil)
                }.padding().background(.regularMaterial)
            }
            .refreshable { await loadAccount() }
            .sheet(isPresented: $showingPeople) {
                NavigationStack {
                    List {
                        Section {
                            Button("仅家庭时光 · 取消全部关联") { selectPeople([]) }
                            Text("已选：\(chosenNames)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Section("人物、孩子与宠物可多选") {
                            ForEach(profiles.filter { profileSearch.isEmpty || $0.label.localizedCaseInsensitiveContains(profileSearch) }) { profile in
                                Button {
                                    var updated = children
                                    if !updated.insert(profile.id).inserted { updated.remove(profile.id) }
                                    selectPeople(updated)
                                    UISelectionFeedbackGenerator().selectionChanged()
                                } label: {
                                    HStack {
                                        Label(profile.label, systemImage: profile.profile_type == "pet" ? "pawprint" : "person.crop.circle")
                                        Spacer()
                                        if children.contains(profile.id) { Image(systemName: "checkmark.circle.fill") }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityAddTraits(children.contains(profile.id) ? .isSelected : [])
                            }
                        }
                    }.navigationTitle("关联人物与宠物")
                        .searchable(text: $profileSearch, prompt: "搜索人物或宠物")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingPeople = false } } }
                }
            }
            .confirmationDialog("取消后会删除本机缓存，继续上传需要重新选择原件", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible) {
                if let item = cancelling { Button("取消此任务", role: .destructive) { queue.cancel(item.id); cancelling = nil } }
            }
            .onChange(of: queue.duplicateNotice.isEmpty) { empty in
                if !empty { showingDuplicate = true }
            }
            .task { queue.configure(session: session); if !hasLoaded { await loadAccount() } }
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
                    queue.confirm(ids: confirmingIDs, childIDs: Array(children), batchName: batchName,
                                  archiveDate: useArchiveDate ? formatter.string(from: archiveDate) : nil)
                }
                Button("返回检查", role: .cancel) { }
            } message: {
                Text("\(confirmationItems.count) 项，\(ByteCountFormatter.string(fromByteCount: confirmationItems.reduce(0) { $0 + $1.size }, countStyle: .file))。关联：\(chosenNames)。\(useArchiveDate ? "全部归档到所选日期，保留原始拍摄时间。" : "按原始拍摄日期归档；没有可靠日期的保持未知。")\(confirmationItems.contains { !$0.warning.isEmpty } ? "部分项目含原件或元数据提示，请确认已阅读每项说明。" : "")")
            }
        }
    }
    private func selectPeople(_ ids: Set<Int>) {
        guard let account, account.id == session.account?.id, hasLoaded else { return }
        children = ids.intersection(Set(profiles.map(\.id)))
        UploadProfilePreferences(site: site, ownerID: account.id).save(children)
    }
    private func loadAccount() async {
        guard !loadingAccount, let expectedOwner = session.account?.id else { return }
        loadingAccount = true
        defer { loadingAccount = false }
        do {
            async let currentRequest: UploadAccount = session.get("/auth/me")
            async let profilesRequest: [UploadProfile] = session.get("/children")
            let (current, loaded) = try await (currentRequest, profilesRequest)
            try Task.checkCancellation()
            guard current.id == expectedOwner, session.account?.id == expectedOwner,
                  ["admin", "member"].contains(current.role) else {
                account = nil
                throw UploadFailure(message: "当前账号没有上传权限，请重新登录。")
            }
            let previousBatch = items.last(where: { $0.confirmed })?.childIDs
            let remembered = UploadProfilePreferences(site: site, ownerID: current.id)
                .restore(validIDs: Set(loaded.map(\.id)), fallback: previousBatch)
            account = current; profiles = loaded; children = remembered
            hasLoaded = true; message = ""
        } catch {
            if Task.isCancelled { return }
            if !hasLoaded { account = nil }
            message = error is URLError ? "无法连接家庭站点，请检查网络。已保存的人物选择不会丢失。" : error.localizedDescription
        }
    }
    private func choosePhotos() async {
        guard !openingPicker, !showPicker, account != nil else { return }
        openingPicker = true
        defer { openingPicker = false }
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

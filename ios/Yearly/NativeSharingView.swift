import SwiftUI
import LinkPresentation

struct NativeShareRequest: Identifiable {
    let id = UUID()
    var day: String? = nil
    var items: [NativeTimelineItem]? = nil
}

struct NativeSharingView: View {
    private enum StartMode: String, CaseIterable, Identifiable {
        case earliest = "从最早的回忆", year = "最近一年", halfYear = "最近半年", custom = "自定义"
        var id: Self { self }
    }
    private struct Bounds: Decodable { let earliest: String?; let latest: String? }

    let selectedItems: [NativeTimelineItem]?
    private var selectionMode: Bool { selectedItems != nil }
    @StateObject private var store: NativeSharingStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var profiles: [UploadProfile] = []
    @State private var profileID: Int?
    @State private var preparingShare = false
    private var selectedProfile: UploadProfile? { profiles.first { $0.id == profileID } }
    @State private var start: Date
    @State private var end: Date
    @State private var startMode: StartMode
    @State private var earliest: Date?
    @State private var latest: Date?
    @State private var hoursText = "24"
    private var hours: Int { Int(hoursText) ?? 0 }
    @State private var confirming = false
    @State private var revoking: NativeShare?
    @State private var copying: NativeShare?
    @State private var revealed: (id: Int, url: URL)?
    @State private var copiedID: Int?
    @State private var systemShare: NativeShareActivityItem?
    @State private var dateRangeError = ""
    @State private var loadingRange = false
    init(session: NativeSession, day: String? = nil, selectedItems: [NativeTimelineItem]? = nil) {
        self.selectedItems = selectedItems
        _store = StateObject(wrappedValue: NativeSharingStore(session: session))
        let date = day.flatMap(NativeDay.date) ?? Date()
        _start = State(initialValue: date); _end = State(initialValue: date)
        _startMode = State(initialValue: day.flatMap(NativeDay.date) == nil ? .earliest : .custom)
    }

    private var resolvedStart: Date? {
        switch startMode {
        case .earliest: earliest
        case .year: Calendar.current.date(byAdding: .month, value: -12, to: Date())
        case .halfYear: Calendar.current.date(byAdding: .month, value: -6, to: Date())
        case .custom: start
        }
    }

    private var valid: Bool {
        guard (1...168).contains(hours), title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count <= 120,
              !store.busy, store.session.canEdit else { return false }
        if let selectedItems { return (1...200).contains(selectedItems.count) }
        return resolvedStart.map { NativeDay.string($0) <= NativeDay.string(end) } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("分享家庭时光") {
                    Picker("分享人物", selection: $profileID) {
                        Text("全部家庭成员").tag(nil as Int?)
                        ForEach(profiles) { profile in Text(profile.label).tag(Optional(profile.id)) }
                    }
                    if let profile = selectedProfile {
                        HStack {
                            NativeFamilyAvatar(session: store.session, mediaID: profile.avatar_media_id,
                                               name: profile.nickname.isEmpty ? profile.name : profile.nickname,
                                               pet: profile.profile_type == "pet", color: NativeTheme.accent, size: 40)
                            Text("仅分享关联此人物的内容，卡片使用其名字和头像。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    TextField("分享标题（可留空）", text: $title)
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 120 {
                        Text("分享标题最多 120 个字符。").font(.caption).foregroundStyle(.red)
                    }
                    if !selectionMode {
                        Picker("开始范围", selection: $startMode) {
                            ForEach(StartMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                        }
                        if startMode == .custom {
                            DatePicker("开始日期", selection: $start, displayedComponents: .date)
                        } else if let resolvedStart {
                            LabeledContent("开始日期", value: NativeDay.string(resolvedStart))
                        }
                        DatePicker("结束日期", selection: $end, displayedComponents: .date)
                        HStack {
                            Button("截至今天") { end = Date() }
                            if let latest { Button("截至最新回忆") { end = latest } }
                        }.buttonStyle(NativeActionStyle(compact: true))
                        if loadingRange { ProgressView("正在查询可分享日期…") }
                        if !dateRangeError.isEmpty {
                            Text(dateRangeError).foregroundStyle(.secondary)
                            Button("重新查询可分享日期") { Task { await loadBounds() } }
                        }
                        if let resolvedStart, NativeDay.string(resolvedStart) > NativeDay.string(end) {
                            Text("结束日期不能早于开始日期。").font(.footnote).foregroundStyle(.red)
                        }
                    } else {
                        Label("仅分享所选 \(selectedItems?.count ?? 0) 项影像", systemImage: "checkmark.circle")
                        if !(1...200).contains(selectedItems?.count ?? 0) {
                            Text("请选择 1 至 200 项影像。").font(.caption).foregroundStyle(.red)
                        }
                    }
                    LabeledContent("有效期（小时）") {
                        TextField("1 至 168", text: $hoursText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        ForEach([1, 24, 72, 168], id: \.self) { value in
                            Button(value < 24 ? "1 小时" : "\(value / 24) 天") { hoursText = String(value) }
                                .buttonStyle(NativeActionStyle(kind: hours == value ? .primary : .secondary, compact: true))
                        }
                    }.buttonStyle(.borderless)
                    if !(1...168).contains(hours) {
                        Text("有效期须为 1 至 168 的整数小时。").font(.footnote).foregroundStyle(.red)
                    }
                    Text(selectionMode ? "链接仅包含下方确认的影像，选定人物时进一步按此人物筛选。Live Photo 作为一项完整分享。" : profileID != nil ? "链接包含所选日期内关联此人物且允许分享的回忆。普通成员仅能分享自己添加的内容。" : store.session.isAdmin ? "链接包含所选日期内允许分享的全部家庭回忆，不受上传人、搜索和类型筛选影响。" : "链接仅包含所选日期内自己添加且允许分享的回忆，该日期内以后新增的本人内容也会出现。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("收到链接的人无需登录，只能查看预览。原件下载和编辑不开放，实况图沿用现有完整播放方式。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { confirming = true } label: {
                        Label("创建限时分享链接", systemImage: "link")
                    }.buttonStyle(NativeActionStyle(kind: .primary)).disabled(!valid)
                }
                if let selectedItems {
                    Section("确认所选内容") {
                        ForEach(selectedItems) { item in
                            HStack {
                                if let file = item.primary {
                                    NativeMediaImage(session: store.session, mediaID: item.id, fileID: file.id).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                VStack(alignment: .leading) {
                                    Text(item.primary?.original_filename ?? item.label).lineLimit(2)
                                    Text(item.media_type == "live_photo" ? "LIVE · 图片与动态资源" : item.media_type == "video" ? "视频" : "照片").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let created = store.created {
                    Section("刚创建的分享") {
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                if let url = created.link(site: store.session.site) {
                                    linkActions(url, share: created)
                                } else { Text(created.revoked ? "这条链接已撤销" : "这条链接已到期") }
                            }
                        }
                    }
                }
                if store.busy { ProgressView("正在处理…") }
                if !store.error.isEmpty { Section { Text(store.error).foregroundStyle(.red); Button("重新加载记录") { Task { await store.load() } }.disabled(store.busy) } }
                Section("分享记录 · 最近 100 条") {
                    if store.shares.isEmpty && !store.busy { Text("还没有分享记录").foregroundStyle(.secondary) }
                    ForEach(store.shares) { share in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(share.displayTitle).font(.headline)
                            Text(share.scope == "selection" ? "指定影像 · \(share.selected_count ?? 0) 项" : "\(share.start_date) — \(share.end_date)").font(.caption)
                            Text("访问 \(share.visit_count ?? 0) 次 · 访客 \(share.visitor_count ?? 0) 人（按客户端去重）").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            TimelineView(.periodic(from: .now, by: 15)) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(share.revoked ? "已撤销" : share.usable ? "生效中" : "已到期").font(.caption).foregroundStyle(.secondary)
                                    if let date = share.expiration { Text("到期：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                                    if share.usable {
                                        if let url = share.link(site: store.session.site) ?? (revealed?.id == share.id ? revealed?.url : nil) {
                                            linkActions(url, share: share)
                                        } else if share.link_available == true {
                                            Button("查看链接", systemImage: "link") {
                                                Task { if let url = await store.link(for: share) { revealed = (share.id, url) } }
                                            }.disabled(store.busy)
                                        }
                                        Button("撤销链接", role: .destructive) { revoking = share }.disabled(store.busy)
                                    }
                                    if share.can_copy == true && (share.link_available != true || !share.usable) {
                                        Button("按原范围创建新链接", systemImage: "link.badge.plus") { copying = share }
                                            .disabled(store.busy || !(1...168).contains(hours))
                                    }
                                }
                            }
                        }.buttonStyle(NativeActionStyle(compact: true)).padding(.vertical, 4)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle("分享管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await store.load() }
            .task {
                do { profiles = try await store.session.get("/children") }
                catch { store.error = friendly(error) }
            }
            .task { if !selectionMode { await loadBounds() } }
            .refreshable { await store.load() }
            .scrollDismissesKeyboard(.interactively)
            .alert(selectionMode ? "确认分享所选影像" : "确认分享日期范围", isPresented: $confirming) {
                Button("创建链接") { Task { await store.create(title: title, start: resolvedStart ?? start, end: end, hours: hours, mediaIDs: selectedItems?.map(\.id), profileID: profileID) } }
                Button("返回检查", role: .cancel) { }
            } message: { Text((selectionMode ? "分享所选 \(selectedItems?.count ?? 0) 项影像。" : "\(NativeDay.string(resolvedStart ?? start)) 至 \(NativeDay.string(end)) 的可分享回忆。") + (selectedProfile.map { "仅包含关联\($0.nickname.isEmpty ? $0.name : $0.nickname)的内容。" } ?? "") + "有效期 \(hours) 小时，持链接者可查看。") }
            .confirmationDialog("撤销后，收到链接的人将无法再打开", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                if let share = revoking { Button("撤销分享", role: .destructive) { Task { await store.revoke(share) }; revoking = nil } }
            }
            .confirmationDialog("按原分享范围生成有效期 \(hours) 小时的新链接", isPresented: Binding(get: { copying != nil }, set: { if !$0 { copying = nil } }), titleVisibility: .visible) {
                if let share = copying { Button("创建新链接") { Task { await store.createCopy(of: share, hours: hours) }; copying = nil } }
            }
            .sheet(item: $systemShare) { item in
                NativeShareActivityView(item: item)
            }
        }
    }

    private func linkActions(_ url: URL, share: NativeShare) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: url) { Label("打开分享网页", systemImage: "safari") }
            Button {
                UIPasteboard.general.setItems([["public.url": url, "public.utf8-plain-text": url.absoluteString]], options: [.localOnly: true, .expirationDate: share.expiration ?? Date()])
                copiedID = share.id
            } label: { Label(copiedID == share.id ? "已复制链接" : "复制分享链接", systemImage: "doc.on.doc") }
            Button {
                Task {
                    preparingShare = true
                    defer { preparingShare = false }
                    var avatar: UIImage?
                    if share.has_avatar == true {
                        do {
                            let resource: NativeMediaResource = try await store.session.get("/public/shares/\(url.lastPathComponent)/avatar?redirect=false")
                            if let raw = resource.url, let imageURL = AppConfiguration.httpsURL(raw) {
                                avatar = try await NativeMediaNetwork.image(imageURL, maximumDimension: 256)
                            }
                        } catch { store.error = friendly(error) }
                    }
                    systemShare = NativeShareActivityItem(url: url, title: share.displayTitle, image: avatar)
                }
            } label: { Label(preparingShare ? "准备分享…" : "系统分享", systemImage: "square.and.arrow.up") }
                .disabled(preparingShare)
        }.buttonStyle(.borderless)
    }

    private func loadBounds() async {
        loadingRange = true
        dateRangeError = ""
        defer { loadingRange = false }
        do {
            let bounds: Bounds = try await store.session.get("/shares/bounds")
            earliest = bounds.earliest.flatMap(NativeDay.date)
            latest = bounds.latest.flatMap(NativeDay.date)
            if earliest == nil { dateRangeError = "暂无带日期的可分享回忆，可手动指定日期。" }
        } catch { dateRangeError = friendly(error) }
    }
}

private final class NativeShareActivityItem: NSObject, Identifiable, UIActivityItemSource {
    let url: URL
    let title: String
    let image: UIImage?
    var id: URL { url }

    init(url: URL, title: String, image: UIImage? = nil) {
        self.url = url
        self.title = title
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url as NSURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url as NSURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        if let logo = image ?? UIImage(named: "ShareLogo") {
            metadata.iconProvider = NSItemProvider(object: logo)
            metadata.imageProvider = metadata.iconProvider
        }
        return metadata
    }
}

private struct NativeShareActivityView: UIViewControllerRepresentable {
    let item: NativeShareActivityItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

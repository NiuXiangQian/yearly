import SwiftUI

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
    @State private var start: Date
    @State private var end: Date
    @State private var startMode: StartMode
    @State private var earliest: Date?
    @State private var latest: Date?
    @State private var hours = 24
    @State private var confirming = false
    @State private var revoking: NativeShare?
    @State private var copying: NativeShare?
    @State private var revealed: (id: Int, url: URL)?
    @State private var copiedID: Int?
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
        guard (1...168).contains(hours), !store.busy, store.session.canEdit else { return false }
        if let selectedItems { return (1...200).contains(selectedItems.count) }
        return resolvedStart.map { NativeDay.string($0) <= NativeDay.string(end) } == true
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("分享家庭时光") {
                    TextField("分享标题（可留空）", text: $title)
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
                    } else { Label("仅分享所选 \(selectedItems?.count ?? 0) 项影像", systemImage: "checkmark.circle") }
                    LabeledContent("有效期（小时）") {
                        TextField("1 至 168", value: $hours, format: .number)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    HStack {
                        ForEach([1, 24, 72, 168], id: \.self) { value in
                            Button(value < 24 ? "1 小时" : "\(value / 24) 天") { hours = value }
                                .buttonStyle(NativeActionStyle(kind: hours == value ? .primary : .secondary, compact: true))
                        }
                    }.buttonStyle(.borderless)
                    if !(1...168).contains(hours) {
                        Text("有效期须为 1 至 168 小时。").font(.footnote).foregroundStyle(.red)
                    }
                    Text(selectionMode ? "链接仅包含下方确认的影像。同一天、同一文件夹的其他内容及以后新增的照片不会加入。Live Photo 作为一项完整分享。" : store.session.isAdmin ? "链接包含所选日期内允许分享的全部家庭回忆，不受人物、上传人、搜索和类型筛选影响。" : "链接仅包含所选日期内自己添加且允许分享的回忆，该日期内以后新增的本人内容也会出现。")
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
                            Text(share.title.isEmpty ? "家庭时光" : share.title).font(.headline)
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
            .task { if !selectionMode { await loadBounds() } }
            .refreshable { await store.load() }
            .scrollDismissesKeyboard(.interactively)
            .alert(selectionMode ? "确认分享所选影像" : "确认分享日期范围", isPresented: $confirming) {
                Button("创建链接") { Task { await store.create(title: title, start: resolvedStart ?? start, end: end, hours: hours, mediaIDs: selectedItems?.map(\.id)) } }
                Button("返回检查", role: .cancel) { }
            } message: { Text((selectionMode ? "仅分享所选 \(selectedItems?.count ?? 0) 项影像。" : "\(NativeDay.string(resolvedStart ?? start)) 至 \(NativeDay.string(end)) 的全部可分享回忆。") + "有效期 \(hours) 小时，持链接者可查看。") }
            .confirmationDialog("撤销后，收到链接的人将无法再打开", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                if let share = revoking { Button("撤销分享", role: .destructive) { Task { await store.revoke(share) }; revoking = nil } }
            }
            .confirmationDialog("按原分享范围生成有效期 \(hours) 小时的新链接", isPresented: Binding(get: { copying != nil }, set: { if !$0 { copying = nil } }), titleVisibility: .visible) {
                if let share = copying { Button("创建新链接") { Task { await store.createCopy(of: share, hours: hours) }; copying = nil } }
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
            ShareLink(item: url) { Label("系统分享", systemImage: "square.and.arrow.up") }
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

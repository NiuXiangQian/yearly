import SwiftUI

struct NativeMediaInfo: View {
    @ObservedObject var session: NativeSession
    let item: NativeTimelineItem
    let profiles: [UploadProfile]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NativeTimelineItem?
    @State private var tags = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var correction = ""
    @State private var utcOffset = ""
    @State private var archive = Date()
    @State private var useArchive = false
    @State private var message = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("影像信息") {
                    LabeledContent("拍摄时间", value: item.taken_at_local ?? "未知")
                    LabeledContent("归档日期", value: item.day)
                    if let primary = item.primary {
                        Text(primary.original_filename)
                        LabeledContent("原件大小", value: ByteCountFormatter.string(fromByteCount: primary.file_size + (item.motion?.file_size ?? 0), countStyle: .file))
                    }
                }
                if item.kind != "event" && session.canEdit {
                    if draft != nil {
                        Section("整理回忆") {
                            TextField("标题", text: field(\.title))
                            TextField("批次名称", text: field(\.batch_name))
                            TextField("备注", text: field(\.remark), axis: .vertical).lineLimit(2...6)
                            TextField("标签（用逗号分隔）", text: $tags)
                            Toggle("允许分享", isOn: Binding(get: { draft?.share_allowed ?? false }, set: { draft?.share_allowed = $0 }))
                        }
                        Section("时间") {
                            Toggle("指定归档日期", isOn: $useArchive)
                            if useArchive { DatePicker("归档日期", selection: $archive, displayedComponents: .date) }
                            Toggle("拍摄时间未知", isOn: Binding(get: { draft?.time_unknown ?? false }, set: { draft?.time_unknown = $0 }))
                            TextField("校正时间 YYYY-MM-DD HH:mm:ss", text: $correction).keyboardType(.numbersAndPunctuation)
                            TextField("时区偏移（分钟，如 +480）", text: $utcOffset).keyboardType(.numbersAndPunctuation)
                        }
                        Section("地点") {
                            TextField("地点名称", text: field(\.location_name))
                            TextField("纬度", text: $latitude).keyboardType(.numbersAndPunctuation)
                            TextField("经度", text: $longitude).keyboardType(.numbersAndPunctuation)
                        }
                        Section("人物与宠物") {
                            ForEach(profiles) { profile in
                                Toggle(profile.label, isOn: Binding(get: { draft?.child_ids?.contains(profile.id) ?? false }, set: { enabled in
                                    var ids = Set(draft?.child_ids ?? [])
                                    if enabled { ids.insert(profile.id) } else { ids.remove(profile.id) }
                                    draft?.child_ids = ids.sorted()
                                }))
                            }
                        }
                    } else if message.isEmpty { ProgressView("正在读取完整信息…") }
                    else { Button("重新加载") { Task { await load() } } }
                } else {
                    if let remark = item.remark, !remark.isEmpty { Text(remark) }
                    if let place = item.location_name, !place.isEmpty { Text(place) }
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft == nil ? "影像信息" : "编辑影像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(saving) }
                if draft != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "保存中…" : "保存") { Task { await save() } }.disabled(saving)
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .task { if item.kind != "event" && session.canEdit { await load() } }
        }
    }

    private func field(_ key: WritableKeyPath<NativeTimelineItem, String?>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }

    private func load() async {
        message = ""
        do {
            let value: NativeTimelineItem = try await session.get("/media/\(item.id)")
            tags = (value.tags ?? []).joined(separator: ", ")
            latitude = value.latitude.map { String($0) } ?? ""
            longitude = value.longitude.map { String($0) } ?? ""
            correction = value.corrected_taken_at_local ?? ""
            utcOffset = value.corrected_offset_minutes.map { String($0) } ?? ""
            let archived = value.timeline_date.flatMap(NativeDay.date)
            useArchive = archived != nil
            archive = archived ?? NativeDay.date(value.day) ?? Date()
            draft = value
        } catch { message = friendly(error) }
    }

    private func save() async {
        guard let draft, !saving else { return }
        saving = true
        message = ""
        defer { saving = false }
        do {
            let lat = try coordinate(latitude, limit: 90, label: "纬度")
            let lon = try coordinate(longitude, limit: 180, label: "经度")
            let minutes = utcOffset.trimmingCharacters(in: .whitespacesAndNewlines)
            let offset = Int(minutes)
            guard minutes.isEmpty || offset.map({ (-840...840).contains($0) }) == true else {
                throw UploadFailure(message: "时区偏移应为 −840 到 840 的整数分钟。")
            }
            let time = correction.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "T")
            if !time.isEmpty {
                let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?$"#
                guard time.range(of: pattern, options: .regularExpression) != nil else {
                    throw UploadFailure(message: "请按 YYYY-MM-DD HH:mm:ss 输入当地拍摄时间。")
                }
            }
            let originalTags = draft.tags ?? []
            let labels = tags == originalTags.joined(separator: ", ") ? originalTags :
                tags.split(whereSeparator: { $0 == "," || $0 == "，" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard labels.count <= 30, labels.allSatisfy({ $0.count <= 80 }) else {
                throw UploadFailure(message: "最多 30 个标签，每个标签最多 80 个字符。")
            }
            let payload: [String: Any] = [
                "title": draft.title ?? "", "batch_name": draft.batch_name ?? "",
                "remark": draft.remark ?? "", "location_name": draft.location_name ?? "",
                "share_allowed": draft.share_allowed ?? false, "time_unknown": draft.time_unknown ?? false,
                "timeline_date": useArchive ? NativeDay.string(archive) as Any : NSNull(),
                "corrected_taken_at_local": time.isEmpty ? NSNull() : time as Any,
                "corrected_offset_minutes": offset as Any? ?? NSNull(),
                "latitude": lat as Any? ?? NSNull(), "longitude": lon as Any? ?? NSNull(),
                "tags": labels, "child_ids": draft.child_ids ?? [],
            ]
            try await session.write("/media/\(item.id)", json: payload)
            onSaved()
            dismiss()
        } catch { message = friendly(error) }
    }

    private func coordinate(_ text: String, limit: Double, label: String) throws -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let number = Double(value), (-limit...limit).contains(number) else {
            throw UploadFailure(message: "\(label)超出范围，请输入有效数字。")
        }
        return number
    }
}

struct NativeMediaTrash: View {
    @ObservedObject var store: NativeTimelineStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NativeTimelineItem] = []
    @State private var cursor: String?
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty && !busy { Text("回收站没有影像").foregroundStyle(.secondary) }
                ForEach(items, id: \.stableID) { item in
                    HStack {
                        Text(item.primary?.original_filename ?? item.label)
                        Spacer()
                        Button("恢复") { Task { await restore(item) } }.disabled(busy)
                    }
                }
                if busy { ProgressView() }
                if cursor != nil { Button("加载更多") { Task { await load(more: true) } }.disabled(busy) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("影像回收站")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load(more: Bool = false) async {
        guard !busy else { return }
        busy = true
        message = ""
        defer { busy = false }
        do {
            var query = URLComponents()
            query.queryItems = [
                URLQueryItem(name: "status", value: "deleted"),
                URLQueryItem(name: "page_size", value: "40"),
                URLQueryItem(name: "group_folders", value: "false"),
            ]
            if more, let cursor { query.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: NativeTimelinePage = try await store.session.get("/timeline?" + (query.percentEncodedQuery ?? ""))
            let media = page.items.filter { $0.kind == "media" }
            if more { items += media } else { items = media }
            cursor = page.next_cursor
        } catch { message = friendly(error) }
    }

    private func restore(_ item: NativeTimelineItem) async {
        guard !busy else { return }
        busy = true
        message = ""
        defer { busy = false }
        do {
            try await store.session.write("/media/\(item.id)/restore", method: "POST", json: [:])
            items.removeAll { $0.id == item.id }
            await store.load()
        } catch { message = friendly(error) }
    }
}

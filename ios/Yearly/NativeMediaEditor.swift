import SwiftUI

enum NativeLocalDateTime {
    static let zone = TimeZone(secondsFromGMT: 0)!

    private static var formatter: DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        format.isLenient = false
        return format
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return formatter.date(from: String(raw.prefix(19)))
    }

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    static var localNow: Date {
        let now = Date()
        return now.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: now)))
    }
}

struct NativeMediaInfo: View {
    @ObservedObject var session: NativeSession
    let item: NativeTimelineItem
    let profiles: [UploadProfile]
    let onSaved: () -> Void
    @NativeDismiss private var dismiss
    @State private var draft: NativeTimelineItem?
    @State private var tags = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var useCorrection = false
    @State private var correctionDate = NativeLocalDateTime.localNow
    @State private var loadedCorrectionDate: Date?
    @State private var utcOffset = ""
    @State private var archive = Date()
    @State private var useArchive = false
    @State private var message = ""
    @State private var saving = false
    @State private var moving = false
    private var current: NativeTimelineItem { draft ?? item }
    private var editable: Bool { current.editable(by: session.account) }

    var body: some View {
        NavigationStack {
            Form {
                Section("影像信息") {
                    LabeledContent("拍摄时间", value: current.taken_at_local ?? "未知")
                    LabeledContent("归档日期", value: current.day)
                    if let source = current.time_source { LabeledContent("时间来源", value: source) }
                    if let offset = current.taken_offset_minutes { LabeledContent("拍摄时区偏移", value: "\(offset) 分钟") }
                    if let width = current.width, let height = current.height { LabeledContent("尺寸", value: "\(width) × \(height)") }
                    let camera = [current.device_make, current.device_model].compactMap { $0 }.joined(separator: " ")
                    if !camera.isEmpty { LabeledContent("拍摄设备", value: camera) }
                    if let primary = current.primary {
                        LabeledContent("原件", value: primary.original_filename)
                        LabeledContent("原件大小", value: ByteCountFormatter.string(fromByteCount: primary.file_size + (current.motion?.file_size ?? 0), countStyle: .file))
                    }
                }
                Section("归属与修改") {
                    if !editable { Label("已锁定，只能编辑自己添加的内容", systemImage: "lock.fill") }
                    LabeledContent("上传人", value: current.owner_name ?? "历史记录")
                    LabeledContent("修改人", value: current.updated_by_name ?? "暂无记录")
                    if let date = current.updated_at { LabeledContent("修改时间", value: NativeAuditLabels.time(date)) }
                    NavigationLink("修改日志") {
                        NativeAuditView(session: session, resourceType: item.kind == "event" ? "timeline_event" : "media", resourceID: String(item.id))
                    }
                }
                if item.kind != "event" && editable {
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
                            Toggle("校正拍摄时间", isOn: $useCorrection)
                            if useCorrection {
                                DatePicker("当地拍摄时间", selection: $correctionDate)
                                    .environment(\.timeZone, NativeLocalDateTime.zone)
                            }
                            LabeledContent("时区偏移（分钟）") {
                                TextField("随原件", text: $utcOffset)
                                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                            }
                            Menu("选择常用时区", systemImage: "globe") {
                                Button("沿用原件") { utcOffset = "" }
                                Button("中国标准时间 · UTC+08:00") { utcOffset = "480" }
                                Button("协调世界时 · UTC+00:00") { utcOffset = "0" }
                            }
                        }
                        Section("地点") {
                            TextField("地点名称", text: field(\.location_name))
                            TextField("纬度", text: $latitude).keyboardType(.numbersAndPunctuation)
                            TextField("经度", text: $longitude).keyboardType(.numbersAndPunctuation)
                            if !latitude.isEmpty || !longitude.isEmpty {
                                Button("清除坐标") { latitude = ""; longitude = "" }
                            }
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
                        if NativeDay.date(current.day) != nil || current.folder_id != nil {
                            Section("文件夹") {
                                Button("移动到文件夹", systemImage: "folder") { moving = true }
                            }
                        }
                    } else if message.isEmpty { ProgressView("正在读取完整信息…") }
                    else { Button("重新加载") { Task { await load() } } }
                } else {
                    if let remark = current.remark, !remark.isEmpty { Text(remark) }
                    if let place = current.location_name, !place.isEmpty { Text(place) }
                }
                if let files = current.files, !files.isEmpty {
                    Section("文件完整性") {
                        ForEach(files) { file in
                            DisclosureGroup(file.original_filename) {
                                LabeledContent("格式", value: file.mime_type)
                                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: file.file_size, countStyle: .file))
                                if let sha = file.sha256 {
                                    Text("SHA-256\n\(sha)").font(.caption.monospaced()).textSelection(.enabled)
                                }
                                if let crc = file.crc64 { LabeledContent("CRC64", value: crc) }
                            }
                        }
                        if let metadata = current.metadata, let parser = metadata.parser_name {
                            LabeledContent("元数据解析", value: [parser, metadata.parser_version, metadata.parse_status].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .disabled(saving)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle(editable ? "编辑影像" : "影像信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(saving) }
                if draft != nil && editable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "保存中…" : "保存") { Task { await save() } }.buttonStyle(NativeActionStyle(kind: .primary, compact: true)).disabled(saving)
                    }
                }
            }
            .nativeInteractiveDismissDisabled(saving)
            .task { if item.kind != "event" { await load() } }
            .nativeSheet(isPresented: $moving) {
                NativeFolderMove(session: session, items: [current]) { onSaved() }
            }
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
            loadedCorrectionDate = NativeLocalDateTime.date(value.corrected_taken_at_local)
            useCorrection = value.corrected_taken_at_local != nil
            correctionDate = loadedCorrectionDate ?? NativeLocalDateTime.date(value.taken_at_local) ?? NativeLocalDateTime.localNow
            utcOffset = value.corrected_offset_minutes.map { String($0) } ?? ""
            let archived = value.timeline_date.flatMap(NativeDay.date)
            useArchive = archived != nil
            archive = archived ?? NativeDay.date(value.day) ?? Date()
            draft = value
        } catch { message = friendly(error) }
    }

    private func save() async {
        guard let draft, editable, !saving else { return }
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
            let time = useCorrection ? (correctionDate == loadedCorrectionDate ? draft.corrected_taken_at_local : NativeLocalDateTime.string(correctionDate)) : nil
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
                "corrected_taken_at_local": time as Any? ?? NSNull(),
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
    @NativeDismiss private var dismiss
    @State private var items: [NativeTimelineItem] = []
    @State private var cursor: String?
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty && !busy { Text("回收站是空的").foregroundStyle(.secondary) }
                ForEach(items, id: \.stableID) { item in
                    HStack {
                        Text(item.primary?.original_filename ?? item.label)
                        Spacer()
                        if item.editable(by: store.session.account) {
                            Button("恢复") { Task { await restore(item) } }.disabled(busy)
                        } else { Label("已锁定", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if busy { ProgressView() }
                if cursor != nil { Button("加载更多") { Task { await load(more: true) } }.disabled(busy) }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("回收站")
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
            if let uploader = store.uploaderID { query.queryItems?.append(URLQueryItem(name: "owner_id", value: String(uploader))) }
            if more, let cursor { query.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: NativeTimelinePage = try await store.session.get("/timeline?" + (query.percentEncodedQuery ?? ""))
            if more { items += page.items } else { items = page.items }
            cursor = page.next_cursor
        } catch { message = friendly(error) }
    }

    private func restore(_ item: NativeTimelineItem) async {
        guard !busy else { return }
        busy = true
        message = ""
        defer { busy = false }
        do {
            let resource = item.kind == "event" ? "events" : "media"
            try await store.session.write("/\(resource)/\(item.id)/restore", method: "POST", json: [:])
            items.removeAll { $0.stableID == item.stableID }
            await store.load()
        } catch { message = friendly(error) }
    }
}

import SwiftUI

private struct NativeFaceCandidate: Decodable, Identifiable {
    let child_id: Int
    let name: String
    let similarity: Double
    let reference_thumbnail: String
    var id: Int { child_id }
}
private struct NativeDetectedFace: Decodable, Identifiable {
    let id: Int
    let thumbnail: String
    let frame_seconds: Double?
    let child_id: Int?
    let ignored: Bool
    let candidates: [NativeFaceCandidate]
    var choice: Int { ignored ? -1 : child_id ?? 0 }
}
private struct NativeFaceState: Decodable {
    let enabled: Bool
    let ready: Bool
    let message: String
    let analyzed: Bool
    let refresh_supported: Bool?
    let faces: [NativeDetectedFace]
    let child_ids: [Int]
    let auto_linked: Int?
    let auto_reset: Int?
}
private struct NativeFaceThumbnail: View {
    let source: String
    var body: some View {
        if let raw = source.split(separator: ",").last, let data = Data(base64Encoded: String(raw)), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 60).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
private struct NativeFaceReview: View {
    @ObservedObject var session: NativeSession
    let mediaID: Int
    let profiles: [UploadProfile]
    @Binding var linkedIDs: [Int]
    @Binding var busy: Bool
    let onSaved: () -> Void
    @State private var expanded = false
    @State private var state: NativeFaceState?
    @State private var choices: [Int: Int] = [:]
    @State private var message = ""
    @State private var notice = ""
    @State private var autoLinkedCount = 0
    @State private var clearing = false
    private var changed: Bool { state?.faces.contains { choices[$0.id] != $0.choice } ?? false }

    var body: some View {
        Section("人脸匹配") {
            DisclosureGroup("确认这里面有谁", isExpanded: $expanded) {
                Text("选择每张脸对应的人物。人工确认后会关联档案并建立参考样本，服务端可据此自动关联其他明确匹配的人脸。")
                    .font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView("正在处理人脸，请稍候…") }
                if let state {
                    if !state.enabled || !state.ready { Text(state.message).font(.caption) }
                    if !state.analyzed {
                        Button("查找这份影像中的人脸") { Task { await perform("analyze") } }.disabled(busy || !state.enabled || !state.ready)
                    } else {
                        if state.refresh_supported == true {
                            Button("重新查找人脸") { Task { await perform("refresh") } }
                                .disabled(busy || changed || !state.enabled || !state.ready)
                            Text("保留已确认和忽略的记录，补查遗漏的人脸。请先保存当前选择。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if state.faces.isEmpty { Text("未检测到清晰人脸，可继续手动关联人物。").font(.caption) }
                        ForEach(Array(state.faces.enumerated()), id: \.element.id) { number, face in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    NativeFaceThumbnail(source: face.thumbnail).accessibilityLabel("待确认人脸 \(number + 1)")
                                    VStack(alignment: .leading) {
                                        Text("人脸 \(number + 1)")
                                        if let seconds = face.frame_seconds { Text("视频 \(seconds, specifier: "%.1f") 秒").font(.caption) }
                                        Picker("人物", selection: Binding(get: { choices[face.id] ?? 0 }, set: { choices[face.id] = $0 })) {
                                            Text("待确认").tag(0)
                                            ForEach(profiles.filter { $0.profile_type != "pet" }) { person in Text(person.name).tag(person.id) }
                                            Text("忽略这张脸").tag(-1)
                                        }
                                    }
                                }
                                if face.child_id == nil && !face.ignored && face.candidates.isEmpty {
                                    Text("没有足够相似的已确认样本，请手动选择。").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(face.candidates) { candidate in
                                    HStack {
                                        NativeFaceThumbnail(source: candidate.reference_thumbnail).accessibilityLabel("\(candidate.name) 的参考样本")
                                        VStack(alignment: .leading) {
                                            Text("可能是 \(candidate.name)")
                                            Text("相似度 \(candidate.similarity, specifier: "%.2f")，供人工判断").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("选择") { choices[face.id] = candidate.child_id }.buttonStyle(.borderless)
                                    }
                                }
                            }.padding(.vertical, 6)
                        }
                        if !state.faces.isEmpty {
                            Button("确认人物") { Task { await perform("confirm") } }.disabled(busy || !changed)
                        }
                        Button("清除本影像的人脸样本", role: .destructive) { clearing = true }
                            .confirmationDialog("清除后将移除这些匹配样本及其新增的人物关联，手动关联保留。", isPresented: $clearing, titleVisibility: .visible) {
                                Button("清除样本", role: .destructive) { Task { await perform("clear") } }
                            }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(NativeTheme.accent) }
                if state == nil && !busy { Button("重新加载") { Task { await perform("load") } } }
            }
        }.alert("已自动整理相似人脸", isPresented: Binding(get: { autoLinkedCount > 0 }, set: { if !$0 { autoLinkedCount = 0 } })) {
            Button("知道了", role: .cancel) { autoLinkedCount = 0 }
        } message: { Text("已将另外 \(autoLinkedCount) 张明确匹配的人脸关联到对应人物，可在已处理项中查看和修改。") }
        .onChange(of: expanded) { value in
            if value && state == nil { Task { await perform("load") } }
        }
    }

    private func perform(_ action: String) async {
        guard !busy else { return }
        busy = true; message = ""; notice = ""
        defer { busy = false }
        do {
            let path = "/faces/media/\(mediaID)"
            let value: NativeFaceState
            if action == "analyze" || action == "refresh" {
                value = try await session.post(path + "/analyze", json: ["refresh": action == "refresh"])
            } else if action == "confirm" {
                let assignments: [[String: Any]] = (state?.faces ?? []).filter { choices[$0.id] != $0.choice }.map { face in
                    let choice = choices[face.id] ?? 0
                    return ["face_id": face.id, "child_id": choice > 0 ? choice as Any : NSNull(), "ignored": choice == -1]
                }
                value = try await session.put(path + "/confirm", json: ["assignments": assignments])
                autoLinkedCount = value.auto_linked ?? 0
                notice = "人物已确认，另自动关联 \(value.auto_linked ?? 0) 张相关人脸。"
                if let reset = value.auto_reset, reset > 0 { notice += "另撤回 \(reset) 条不再明确的自动关联。" }
            } else if action == "clear" {
                try await session.write(path, method: "DELETE", json: [:])
                value = try await session.get(path, refresh: true)
            } else {
                value = try await session.get(path, refresh: true)
            }
            if action == "confirm" || action == "clear" || action == "analyze" || action == "refresh" {
                let old = Set(state?.child_ids ?? []), next = Set(value.child_ids)
                linkedIDs = Array(Set(linkedIDs).subtracting(old.subtracting(next)).union(next.subtracting(old))).sorted()
                onSaved()
            }
            state = value
            choices = Dictionary(uniqueKeysWithValues: value.faces.map { ($0.id, $0.choice) })
        } catch { message = friendly(error) }
    }
}

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
    @State private var faceBusy = false
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
                        if session.isAdmin {
                            NativeFaceReview(session: session, mediaID: item.id, profiles: profiles,
                                linkedIDs: Binding(get: { draft?.child_ids ?? [] }, set: { draft?.child_ids = $0 }),
                                busy: $faceBusy, onSaved: onSaved)
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
            .disabled(saving || faceBusy)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle(editable ? "编辑影像" : "影像信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(saving || faceBusy) }
                if draft != nil && editable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "保存中…" : "保存") { Task { await save() } }.buttonStyle(NativeActionStyle(kind: .primary, compact: true)).disabled(saving || faceBusy)
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
        guard let draft, editable, !saving, !faceBusy else { return }
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

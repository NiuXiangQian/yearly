import SwiftUI

struct NativeDiaryRequest: Identifiable {
    let id = UUID()
    var day: String?
    var items: [NativeTimelineItem] = []
}

struct NativeDiaryEditor: View {
    let session: NativeSession
    let profiles: [UploadProfile]
    var existing: NativeTimelineItem?
    var request: NativeDiaryRequest?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var start = NativeLocalDateTime.localNow
    @State private var end = NativeLocalDateTime.localNow
    @State private var useStart = false
    @State private var useEnd = false
    @State private var originalStart: String?
    @State private var originalEnd: String?
    @State private var people: Set<Int> = []
    @State private var linked: [NativeTimelineItem] = []
    @State private var linkedIDs: [Int] = []
    @State private var cover: Int?
    @State private var allowed = true
    @State private var permitted = false
    @State private var modifier: String?
    @State private var ready = false
    @State private var busy = false
    @State private var deleting = false
    @State private var failure = ""

    private struct Diary: Decodable {
        let title: String
        let content: String
        let start_at: String?
        let end_at: String?
        let cover_media_id: Int?
        let child_ids: [Int]
        let media_ids: [Int]
        let media: [NativeTimelineItem]
        let share_allowed: Bool
        let can_edit: Bool?
        let created_by: Int?
        let updated_by_name: String?
    }

    var body: some View {
        NavigationStack {
            Form {
                if ready {
                    Group {
                    Section("日记内容") {
                        TextField("标题", text: $title)
                        TextField("记录这段回忆", text: $content, axis: .vertical).lineLimit(4...12)
                        Toggle("允许分享日记", isOn: $allowed)
                    }
                    Section("时间") {
                        Toggle("设置开始时间", isOn: $useStart)
                        if useStart { DatePicker("开始时间", selection: $start).environment(\.timeZone, NativeLocalDateTime.zone) }
                        Toggle("设置结束时间", isOn: $useEnd)
                        if useEnd { DatePicker("结束时间", selection: $end).environment(\.timeZone, NativeLocalDateTime.zone) }
                    }
                    Section("人物与宠物") {
                        ForEach(profiles) { profile in
                            Toggle(profile.label, isOn: Binding(get: { people.contains(profile.id) }, set: {
                                if $0 { people.insert(profile.id) } else { people.remove(profile.id) }
                            }))
                        }
                    }
                    if !linkedIDs.isEmpty {
                        Section("关联影像") {
                            Picker("日记封面", selection: $cover) {
                                Text("自动").tag(nil as Int?)
                                ForEach(linked.filter { linkedIDs.contains($0.id) }) { item in
                                    Text(item.primary?.original_filename ?? item.label).tag(Optional(item.id))
                                }
                                if let cover, !linked.contains(where: { $0.id == cover }) {
                                    Text("原封面").tag(Optional(cover))
                                }
                            }
                            ForEach(linked.filter { linkedIDs.contains($0.id) }) { item in
                                Button("移除 \(item.primary?.original_filename ?? item.label)", systemImage: "minus.circle", role: .destructive) {
                                    linkedIDs.removeAll { $0 == item.id }
                                    if cover == item.id { cover = nil }
                                }
                            }
                        }
                    }
                    if existing != nil && permitted {
                        Button("移到回收站", role: .destructive) { deleting = true }
                    }
                    }.disabled(!permitted)
                    if let existing {
                        Section("修改记录") {
                            if !permitted { Label("已锁定，只能编辑自己添加的日记", systemImage: "lock.fill") }
                            LabeledContent("修改人", value: modifier ?? "暂无记录")
                            NavigationLink("修改日志") { NativeAuditView(session: session, resourceType: "timeline_event", resourceID: String(existing.id)) }
                        }
                    }
                } else if !busy { Button("重新加载日记") { Task { await load() } } }
                if busy { ProgressView("正在处理…") }
                if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle(existing == nil ? "写日记" : "编辑日记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .buttonStyle(NativeActionStyle(kind: .primary, compact: true))
                        .disabled(!permitted || !ready || busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  title.count > 255 || content.count > 50_000 || (useStart && useEnd && end < start))
                }
            }
            .interactiveDismissDisabled(busy)
            .task { await load() }
            .confirmationDialog("将日记移到回收站？", isPresented: $deleting, titleVisibility: .visible) {
                Button("移到回收站", role: .destructive) { Task { await save(remove: true) } }
            } message: { Text("关联的影像仍保存在时间线中。") }
        }
    }

    private func load() async {
        guard !ready, !busy else { return }
        busy = true; failure = ""
        defer { busy = false }
        do {
            if let existing {
                let diary: Diary = try await session.get("/events/\(existing.id)")
                permitted = session.account?.canEdit(ownerID: diary.created_by, allowed: diary.can_edit) ?? false
                modifier = diary.updated_by_name
                title = diary.title; content = diary.content; people = Set(diary.child_ids)
                linked = diary.media; linkedIDs = diary.media_ids; cover = diary.cover_media_id; allowed = diary.share_allowed
                originalStart = diary.start_at; originalEnd = diary.end_at
                if let value = NativeLocalDateTime.date(diary.start_at) { start = value; useStart = true }
                if let value = NativeLocalDateTime.date(diary.end_at) { end = value; useEnd = true }
            } else {
                permitted = session.canEdit
                linked = request?.items ?? []
                linkedIDs = linked.map(\.id)
                if let day = request?.day, let date = NativeLocalDateTime.date(day + "T00:00:00") {
                    start = date; end = date; useStart = true
                }
            }
            ready = true
        } catch { failure = friendly(error) }
    }

    private func save(remove: Bool = false) async {
        guard permitted, !busy else { return }
        busy = true; failure = ""
        defer { busy = false }
        do {
            if remove, let existing {
                try await session.write("/events/\(existing.id)", method: "DELETE", json: [:])
            } else {
                let startValue = start == NativeLocalDateTime.date(originalStart) ? originalStart : NativeLocalDateTime.string(start)
                let endValue = end == NativeLocalDateTime.date(originalEnd) ? originalEnd : NativeLocalDateTime.string(end)
                let payload: [String: Any] = [
                    "title": title, "content": content, "share_allowed": allowed, "child_ids": people.sorted(),
                    "media_ids": linkedIDs, "cover_media_id": cover as Any? ?? NSNull(),
                    "start_at": (useStart ? startValue : nil) as Any? ?? NSNull(),
                    "end_at": (useEnd ? endValue : nil) as Any? ?? NSNull(),
                ]
                try await session.write(existing.map { "/events/\($0.id)" } ?? "/events", method: existing == nil ? "POST" : "PUT", json: payload)
            }
            onSaved()
            dismiss()
        } catch { failure = friendly(error) }
    }
}

private struct NativeFolder: Decodable, Identifiable {
    let id: Int
    let name: String
    let media_count: Int
    let share_allowed: Bool
    let can_edit: Bool?
    let owner_id: Int?
    let owner_name: String?
    let updated_by_name: String?
    func editable(by account: UploadAccount?) -> Bool { account?.canEdit(ownerID: owner_id, allowed: can_edit) ?? false }
}

struct NativeDaySettings: View {
    @ObservedObject var store: NativeTimelineStore
    let day: String
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [NativeFolder] = []
    @State private var busy = false
    @State private var status = ""
    @State private var failure = ""
    @State private var reset = false
    @State private var editingFolder: NativeFolder?
    @State private var creatingFolder = false
    private var dated: Bool { NativeDay.date(day) != nil }

    var body: some View {
        NavigationStack {
            Form {
                if dated {
                    Section {
                        Toggle("允许分享当天", isOn: Binding(get: { store.daySharing[day] ?? true }, set: { allowed in
                            Task { await perform("当天分享设置已保存") { try await store.setDaySharing(day, allowed: allowed) } }
                        })).disabled(!store.session.isAdmin)
                        NavigationLink("当天设置修改日志") { NativeAuditView(session: store.session, resourceType: "timeline_day", resourceID: day) }
                    } footer: { Text("管理员可设置当天的分享权限。关闭后，这一天的内容会从现有及新建分享中隐藏。") }
                    Section("当天文件夹") {
                        ForEach(folders) { folder in
                            Button { editingFolder = folder } label: {
                                LabeledContent(folder.name, value: "\(folder.media_count) 项" + (folder.editable(by: store.session.account) ? "" : " · 已锁定"))
                            }
                        }
                        Button("新建文件夹", systemImage: "folder.badge.plus") { creatingFolder = true }
                    }
                }
                Section("排序") {
                    Button("恢复当天默认排序", systemImage: "arrow.counterclockwise") { reset = true }
                        .disabled(store.items.contains { $0.day == day && !$0.editable(by: store.session.account) })
                }
                if busy { ProgressView("正在处理…") }
                if !failure.isEmpty {
                    Text(failure).foregroundStyle(.red)
                    if dated { Button("重新读取文件夹") { Task { await reloadFolders() } } }
                }
                if !status.isEmpty { Label(status, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            .disabled(busy)
            .navigationTitle(dated ? day + " 设置" : "日期未知 · 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if dated { await reloadFolders() } }
            .confirmationDialog("恢复当天默认排序？", isPresented: $reset, titleVisibility: .visible) {
                Button("恢复排序", role: .destructive) {
                    Task {
                        await perform("已恢复默认排序") {
                            try await store.session.write("/media/reset-order", method: "POST", json: ["day": dated ? day as Any : NSNull()])
                            await store.load()
                        }
                    }
                }
            } message: { Text("当天的影像及文件夹会恢复默认排序。") }
            .sheet(item: $editingFolder) { folder in
                NativeFolderEditor(session: store.session, day: day, folder: folder, onSaved: folderChanged)
            }
            .sheet(isPresented: $creatingFolder) {
                NativeFolderEditor(session: store.session, day: day, folder: nil, onSaved: folderChanged)
            }
        }
    }

    private func folderChanged() {
        Task { await reloadFolders(); await store.load() }
    }

    private func reloadFolders() async {
        await perform("") { folders = try await store.session.get("/folders?day=\(day)") }
    }

    private func perform(_ confirmation: String, operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; failure = ""; status = ""
        defer { busy = false }
        do { try await operation(); status = confirmation }
        catch { failure = friendly(error) }
    }
}

private struct NativeFolderEditor: View {
    let session: NativeSession
    let day: String
    let folder: NativeFolder?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var allowed = true
    @State private var busy = false
    @State private var failure = ""
    @State private var deleting = false

    private var editable: Bool { folder.map { $0.editable(by: session.account) } ?? session.canEdit }
    var body: some View {
        NavigationStack {
            Form {
                TextField("文件夹名称", text: $name).disabled(!editable)
                if folder != nil {
                    Toggle("允许分享文件夹及其内容", isOn: $allowed).disabled(!editable)
                    if editable { Button("删除文件夹", role: .destructive) { deleting = true } }
                    if let folder {
                        if !editable { Label("已锁定", systemImage: "lock.fill") }
                        LabeledContent("创建人", value: folder.owner_name ?? "历史记录")
                        LabeledContent("修改人", value: folder.updated_by_name ?? "暂无记录")
                        NavigationLink("修改日志") { NativeAuditView(session: session, resourceType: "timeline_folder", resourceID: String(folder.id)) }
                    }
                }
                if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle(folder == nil ? "新建文件夹" : "编辑文件夹")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(!editable || busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 255)
                }
            }
            .onAppear { name = folder?.name ?? ""; allowed = folder?.share_allowed ?? true }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("删除文件夹？", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除文件夹", role: .destructive) { Task { await save(remove: true) } }
            } message: { Text("文件夹内的影像会回到当天时间线。") }
        }
    }

    private func save(remove: Bool = false) async {
        guard editable, !busy else { return }
        busy = true; failure = ""
        defer { busy = false }
        do {
            if let folder {
                try await session.write("/folders/\(folder.id)", method: remove ? "DELETE" : "PUT",
                                        json: remove ? [:] : ["name": name, "share_allowed": allowed])
            } else {
                try await session.write("/folders", method: "POST", json: ["name": name, "timeline_date": day])
            }
            onSaved()
            dismiss()
        } catch { failure = friendly(error) }
    }
}

struct NativeFolderMove: View {
    let session: NativeSession
    let items: [NativeTimelineItem]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [NativeFolder] = []
    @State private var busy = false
    @State private var failure = ""
    private var day: String? {
        guard let first = items.first?.day, NativeDay.date(first) != nil, items.allSatisfy({ $0.day == first }) else { return nil }
        return first
    }

    var body: some View {
        NavigationStack {
            List {
                if items.contains(where: { $0.folder_id != nil }) {
                    Button("移回当天时间线", systemImage: "arrow.uturn.backward") { Task { await move(to: nil) } }
                }
                ForEach(folders) { folder in
                    Button(folder.name, systemImage: "folder") { Task { await move(to: folder.id) } }
                        .disabled(!folder.editable(by: session.account) || items.allSatisfy { $0.folder_id == folder.id })
                }
                if busy { ProgressView("正在处理…") }
                else if day == nil { Text("选择同一天的影像，即可移入当天文件夹。") }
                else if folders.isEmpty && failure.isEmpty { Text("当天没有文件夹，可从当天设置新建。") }
                if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("移动 \(items.count) 项影像")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
            .task {
                guard let day else { return }
                busy = true
                defer { busy = false }
                do { folders = try await session.get("/folders?day=\(day)") }
                catch { failure = friendly(error) }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func move(to folder: Int?) async {
        guard !busy else { return }
        busy = true; failure = ""
        defer { busy = false }
        do {
            try await session.write("/folders/move-media", method: "POST", json: [
                "media_ids": items.map(\.id), "folder_id": folder as Any? ?? NSNull(),
            ])
            onSaved()
            dismiss()
        } catch { failure = friendly(error) }
    }
}

struct NativeBatchMediaEditor: View {
    private enum PeopleMode: String, CaseIterable {
        case add, remove, replace
        var label: String {
            switch self { case .add: "追加"; case .remove: "移除"; case .replace: "替换" }
        }
    }
    @ObservedObject var store: NativeTimelineStore
    let items: [NativeTimelineItem]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editBatch = false
    @State private var editArchive = false
    @State private var clearArchive = false
    @State private var date = Date()
    @State private var batch = ""
    @State private var mode = PeopleMode.add
    @State private var people: Set<Int> = []
    @State private var busy = false
    @State private var failure = ""
    @State private var moving = false
    @State private var confirmingPeople = false

    var body: some View {
        NavigationStack {
            Form {
                Section("归档与批次") {
                    Toggle("修改批次名称", isOn: $editBatch)
                    if editBatch { TextField("批次名称（留空可清除）", text: $batch) }
                    Toggle("修改归档日期", isOn: $editArchive)
                    if editArchive {
                        Toggle("清除指定归档日期", isOn: $clearArchive)
                        if !clearArchive { DatePicker("归档日期", selection: $date, displayedComponents: .date) }
                    }
                    Button("保存归档与批次") { Task { await organize() } }
                        .buttonStyle(NativeActionStyle(kind: .primary))
                        .disabled((!editBatch && !editArchive) || (editBatch && batch.count > 255))
                }
                Section("人物与宠物") {
                    Picker("关联方式", selection: $mode) {
                        ForEach(PeopleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    ForEach(store.profiles) { profile in
                        Toggle(profile.label, isOn: Binding(get: { people.contains(profile.id) }, set: {
                            if $0 { people.insert(profile.id) } else { people.remove(profile.id) }
                        }))
                    }
                    Button("保存关联") { confirmingPeople = true }.buttonStyle(NativeActionStyle(kind: .primary)).disabled(people.isEmpty && mode != .replace)
                }
                Section("文件夹") { Button("移动到文件夹", systemImage: "folder") { moving = true } }
                if busy { ProgressView("正在保存…") }
                if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("整理 \(items.count) 项影像")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("\(mode.label) \(items.count) 项影像的人物关联？", isPresented: $confirmingPeople, titleVisibility: .visible) {
                Button("保存关联") { Task { await savePeople() } }
            } message: { if mode == .replace && people.isEmpty { Text("将清空所选影像的人物关联。") } }
            .sheet(isPresented: $moving, onDismiss: finishFolderMove) {
                NativeFolderMove(session: store.session, items: items) { moved = true }
            }
        }
    }

    @State private var moved = false

    private func finishFolderMove() {
        guard moved else { return }
        onSaved()
        dismiss()
        Task { await store.load() }
    }

    private func organize() async {
        var changes: [String: Any] = [:]
        if editBatch { changes["batch_name"] = batch }
        if editArchive { changes["timeline_date"] = clearArchive ? NSNull() as Any : NativeDay.string(date) }
        await save("/media/batch-organize", changes: changes)
    }

    private func savePeople() async {
        await save("/media/batch-children", changes: ["mode": mode.rawValue, "child_ids": people.sorted()])
    }

    private func save(_ path: String, changes: [String: Any]) async {
        guard !busy, !items.isEmpty, items.allSatisfy({ $0.editable(by: store.session.account) }) else { return }
        busy = true; failure = ""
        defer { busy = false }
        var payload = changes
        payload["media_ids"] = items.map(\.id)
        do {
            try await store.session.write(path, method: "POST", json: payload)
            onSaved()
            dismiss()
            await store.load()
        } catch { failure = friendly(error) }
    }
}

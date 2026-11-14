import SwiftUI

// Entry points describe the task; each destination owns one workflow.
struct NativeOrganizationHomeView: View {
    let session: NativeSession
    var onUpdated: () -> Void = {}
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把照片整理到家人相册").font(.title2.bold())
                    Text("选择照片，整理到家人或宠物的相册。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }.listRowBackground(Color.clear)
            Section {
                if session.isAdmin {
                    NavigationLink {
                        NativeCurationView(session: session, onUpdated: onUpdated)
                    } label: {
                        NativeOrganizationTaskLabel(title: "整理到家人相册", detail: "选照片，再选择要加入的家人或宠物相册", symbol: "person.crop.rectangle.stack")
                    }
                }
            }
            if session.isAdmin {
                Section("记录与设置") {
                    NavigationLink {
                        NativeMemoryReviewView(session: session, tab: .organization, onUpdated: onUpdated)
                    } label: {
                        Label("自动整理记录", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink {
                        NativeOrganizationSettingsView(session: session)
                    } label: {
                        Label("自动整理设置", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(NativeTheme.background)
        .navigationTitle("照片助手")
    }
}

private struct NativeOrganizationTaskLabel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(NativeTheme.accent)
                .frame(width: 42, height: 42)
                .background(NativeTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 12)
    }
}

struct NativeMemoryReviewView: View {
    @StateObject private var store: NativeMemoryReviewStore
    let onUpdated: () -> Void
    @State private var previewing: NativeTimelineItem?
    @State private var previewSeconds: Double?
    init(session: NativeSession, mediaID: Int? = nil, tab: NativeMemoryReviewStore.Tab = .faces, onUpdated: @escaping () -> Void = {}) {
        _store = StateObject(wrappedValue: NativeMemoryReviewStore(session: session, mediaID: mediaID, tab: tab))
        self.onUpdated = onUpdated
    }
    private var introduction: String {
        switch store.tab {
        case .faces: return "看看照片里是谁，选择对应的家人或宠物。确认后会帮助整理其他明确匹配的照片。"
        case .organization: return "查看自动添加的标签和人物。结果不合适时，可以修改或撤回。"
        }
    }
    var body: some View {
        Group {
            if store.session.isAdmin {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(introduction)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                        Toggle(store.tab == .organization ? "显示全部记录" : "显示已处理的照片", isOn: $store.includeReviewed).disabled(store.busy)
                        if store.mediaID != nil { Text("仅查看当前影像的识别结果").font(.caption).foregroundStyle(.secondary) }
                    }
                    if store.busy { Section { ProgressView("正在处理，请稍候…") } }
                    if !store.error.isEmpty {
                        Section {
                            Text(store.error).foregroundStyle(.red)
                            Button("重新加载") { Task { await store.load() } }.disabled(store.busy)
                        }
                    }
                    if !store.notice.isEmpty { Section { Label(store.notice, systemImage: "checkmark.circle").foregroundStyle(NativeTheme.accent) } }
                    switch store.tab {
                    case .faces: subjectSections
                    case .organization:
                        NativeOrganizationReviewSections(store: store, preview: { media, seconds in previewSeconds = seconds; previewing = media }, onUpdated: onUpdated)
                    }
                    if !store.history.isEmpty || store.nextCursor != nil {
                        Section {
                            HStack {
                                Button("上一页") { Task { await store.page(next: false) } }.disabled(store.history.isEmpty || store.busy)
                                Spacer()
                                Button("下一页") { Task { await store.page(next: true) } }.disabled(store.nextCursor == nil || store.busy)
                            }.frame(minHeight: 44)
                        }
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(NativeTheme.background)
                .refreshable { if !store.busy { await store.load() } }
                .task(id: "\(store.tab)-\(store.includeReviewed)-\(store.organizationKind)") { await store.load(reset: true) }
            } else { Text("整理照片需要管理员权限。").padding() }
        }
        .navigationTitle(store.tab.rawValue).navigationBarTitleDisplayMode(.inline)
        .alert("已自动整理相似人脸", isPresented: Binding(get: { store.autoLinkedCount > 0 }, set: { if !$0 { store.autoLinkedCount = 0 } })) {
            Button("知道了", role: .cancel) { store.autoLinkedCount = 0 }
        } message: { Text("已将另外 \(store.autoLinkedCount) 张明确匹配的人脸关联到对应人物，可在已处理项中查看和修改。") }
        .nativeSheet(item: $previewing) { media in
            NativeMediaDetail(session: store.session, initial: media, profiles: store.profiles, pagePosition: nil, previous: nil, next: nil,
                onSaved: { Task { await store.load(); onUpdated() } },
                onDeleted: { previewing = nil; Task { await store.load(); onUpdated() } }, onLocate: nil, initialPlaybackSeconds: previewSeconds)
        }
    }
    @ViewBuilder private var subjectSections: some View {
        if let queue = store.faces {
            Section {
                LabeledContent("待确认人物", value: "\(queue.pending_faces) 张脸")
                LabeledContent("识别到宠物 · 待确认", value: "\(store.pets?.pending_pets ?? 0) 条")
                if !queue.enabled || !queue.ready { Text(queue.message).font(.caption).foregroundStyle(.secondary) }
                Button(store.mediaID == nil ? "查找更多照片里的人物" : "查找本影像中的人脸", systemImage: "viewfinder") {
                    Task { await store.analyzeNext(); onUpdated() }
                }.disabled(store.busy || !queue.enabled || !queue.ready || (store.mediaID == nil && queue.unanalysed_photos == 0))
                Button(store.mediaID == nil ? "查找更多照片里的宠物" : "识别本影像中的宠物", systemImage: "pawprint") {
                    Task { await store.analyzeNext(pets: true); onUpdated() }
                }.disabled(store.busy || (store.mediaID == nil && store.pets?.unanalysed_media == 0))
                Text("每次确认人物后会自动整理相似人脸，关联到其他人脸时会弹窗提醒。宠物按外观推荐并由你确认。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("集中确认人物与宠物") }
            ForEach(store.subjects) { subject in
                Section {
                    switch subject {
                    case .face(let face, let media): faceRow(face, media)
                    case .pet(let dog, let media): petRow(dog, media)
                    }
                }
            }
            if store.subjects.isEmpty && !store.busy { Section { Text("暂时没有需要确认的人物或宠物。你可以查找更多照片，或打开“显示已处理的照片”修改之前的结果。").foregroundStyle(.secondary) } }
        }
    }
    private func faceRow(_ face: MemoryReviewFace, _ media: NativeTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("识别到人物", systemImage: "person.crop.rectangle").font(.caption.weight(.semibold)).foregroundStyle(NativeTheme.accent)
            HStack(spacing: 14) {
                Button { previewSeconds = face.frame_seconds; previewing = media } label: {
                    MemoryReviewThumbnail(source: face.thumbnail)
                }.buttonStyle(.plain).accessibilityLabel("查看这张人脸的来源照片或视频")
                VStack(alignment: .leading, spacing: 5) {
                    Text(face.ignored ? "已忽略" : face.child_id == nil ? "这张脸是谁？" : "已确认人物").font(.headline)
                    Text(media.day).font(.caption).foregroundStyle(.secondary)
                    if face.auto_assigned == true { Text("自动关联，可人工纠正").font(.caption).foregroundStyle(NativeTheme.accent) }
                    if let seconds = face.frame_seconds { Text("视频 \(seconds, specifier: "%.1f") 秒").font(.caption) }
                }
            }
            sourceButton(media, seconds: face.frame_seconds)
            MemoryCandidateChoices(candidates: face.candidates, choice: faceChoice(face), busy: store.busy)
            Picker("关联人物", selection: faceChoice(face)) {
                Text("待确认").tag(0)
                ForEach(store.people) { Text($0.name).tag($0.id) }
                Text("忽略这张脸").tag(-1)
            }.disabled(store.busy)
            Button("确认人物") { Task { await store.confirm(face: face, mediaID: media.id); onUpdated() } }
                .buttonStyle(NativeActionStyle(kind: .primary)).disabled(store.busy || (faceChoice(face).wrappedValue == face.choice && face.auto_assigned != true))
        }.padding(.vertical, 6)
    }
    private func petRow(_ dog: MemoryDog, _ media: NativeTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("识别到宠物", systemImage: "pawprint.fill").font(.caption.weight(.semibold)).foregroundStyle(NativeTheme.accent)
            HStack(spacing: 14) {
                Button { previewSeconds = dog.frame_seconds; previewing = media } label: {
                    MemoryReviewThumbnail(source: dog.thumbnail)
                }.buttonStyle(.plain).accessibilityLabel("查看这只宠物的来源照片或视频")
                VStack(alignment: .leading, spacing: 5) {
                    Text(dog.ignored ? "已忽略" : dog.child_id == nil ? "这只宠物是谁？" : "已确认宠物").font(.headline)
                    Text(media.day).font(.caption).foregroundStyle(.secondary)
                    Text(dog.appearance).font(.caption).foregroundStyle(.secondary)
                    if let seconds = dog.frame_seconds { Text("视频 \(seconds, specifier: "%.1f") 秒").font(.caption) }
                }
            }
            sourceButton(media, seconds: dog.frame_seconds)
            MemoryCandidateChoices(candidates: dog.candidates, choice: dogChoice(dog, mediaID: media.id), busy: store.busy)
            Picker("关联宠物", selection: dogChoice(dog, mediaID: media.id)) {
                Text("待确认").tag(0)
                ForEach(store.dogs) { Text($0.name).tag($0.id) }
                Text("忽略").tag(-1)
            }.disabled(store.busy)
            Button("确认宠物") { Task { await store.confirm(dog: dog, mediaID: media.id); onUpdated() } }
                .buttonStyle(NativeActionStyle(kind: .primary)).disabled(store.busy || dogChoice(dog, mediaID: media.id).wrappedValue == dog.choice)
        }.padding(.vertical, 6)
    }
    private func sourceButton(_ media: NativeTimelineItem, seconds: Double?) -> some View {
        Button {
            previewSeconds = seconds; previewing = media
        } label: {
            Label(media.media_type == "video" || seconds != nil ? "查看来源视频" : "查看来源照片", systemImage: "photo.on.rectangle")
                .frame(minHeight: 44)
        }.disabled(store.busy)
    }
    private func faceChoice(_ face: MemoryReviewFace) -> Binding<Int> {
        Binding(get: { store.faceChoices[face.id] ?? face.choice }, set: { store.faceChoices[face.id] = $0 })
    }
    private func dogChoice(_ dog: MemoryDog, mediaID: Int) -> Binding<Int> {
        let key = "\(mediaID):\(dog.index)"
        return Binding(get: { store.dogChoices[key] ?? dog.choice }, set: { store.dogChoices[key] = $0 })
    }
}

private struct MemoryReviewThumbnail: View {
    let source: String
    var body: some View {
        Group {
            if let raw = source.split(separator: ",").last, let data = Data(base64Encoded: String(raw)), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "photo").resizable().scaledToFit().padding(16).foregroundStyle(.secondary) }
        }.frame(width: 72, height: 86).clipped().background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("识别区域")
    }
}
private struct MemoryCandidateChoices: View {
    let candidates: [MemoryMatchCandidate]
    @Binding var choice: Int
    let busy: Bool
    var body: some View {
        if candidates.isEmpty { Text("没有足够相似的参考样本，请手动选择。").font(.caption).foregroundStyle(.secondary) }
        ForEach(candidates) { candidate in
            Button { choice = candidate.child_id } label: {
                HStack(spacing: 12) {
                    MemoryReviewThumbnail(source: candidate.reference_thumbnail)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("可能是 \(candidate.name)").font(.subheadline.weight(.semibold))
                        Text("相似度 \(candidate.similarity, specifier: "%.2f")，供人工判断").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: choice == candidate.child_id ? "checkmark.circle.fill" : "circle")
                }.foregroundStyle(NativeTheme.accent).padding(10)
                    .background(NativeTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(busy).accessibilityLabel("选择推荐档案 \(candidate.name)")
        }
    }
}

private struct NativeOrganizationSettingsView: View {
    @StateObject private var store: NativeMemoryReviewStore
    init(session: NativeSession) {
        _store = StateObject(wrappedValue: NativeMemoryReviewStore(session: session, tab: .organization))
    }
    var body: some View {
        Form {
            if store.busy { ProgressView("正在加载…") }
            if !store.error.isEmpty {
                Section { Text(store.error).foregroundStyle(.red)
                    Button("重新加载") { Task { await store.loadOrganizationSettings() } }.disabled(store.busy)
                }
            }
            if !store.notice.isEmpty { Text(store.notice).foregroundStyle(NativeTheme.accent) }
            if store.organizationSettings != nil {
                Section("自动整理") {
                    Toggle("自动添加标签", isOn: Binding(get: { store.organizationSettings?.tags_enabled == true }, set: { store.organizationSettings?.tags_enabled = $0 })).disabled(store.busy)
                    Toggle("自动确认明确匹配的人物与宠物", isOn: Binding(get: { store.organizationSettings?.people_enabled == true }, set: { store.organizationSettings?.people_enabled = $0 })).disabled(store.busy)
                    Text("标签开启后自动保存并确认，无需人工审核。你仍可修改或撤回已保存的结果。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach((store.organizationSettings?.tag_rules.keys.sorted() ?? []), id: \.self) { source in
                        if let rule = store.organizationSettings?.tag_rules[source] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(source) → \(rule.mode == "skip" ? "不再添加" : "自动确认") \(rule.target)").font(.subheadline)
                                Button("移除习惯") { store.organizationSettings?.tag_rules.removeValue(forKey: source) }.disabled(store.busy)
                            }
                        }
                    }
                    ForEach((store.organizationSettings?.person_rules.keys.sorted() ?? []), id: \.self) { id in
                        let name = store.profiles.first { String($0.id) == id }?.name ?? id
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(name) · \(store.organizationSettings?.person_rules[id] == "manual" ? "每次人工确认" : "明确匹配时自动通过")").font(.subheadline)
                            Button("移除习惯") { store.organizationSettings?.person_rules.removeValue(forKey: id) }.disabled(store.busy)
                        }
                    }
                    Button("保存设置") { Task { await store.saveOrganizationSettings() } }.disabled(store.busy)
                }
            }

        }
        .navigationTitle("自动整理设置").navigationBarTitleDisplayMode(.inline)
        .task { await store.loadOrganizationSettings() }
    }
}

private struct NativeOrganizationReviewSections: View {
    @ObservedObject var store: NativeMemoryReviewStore
    let preview: (NativeTimelineItem, Double?) -> Void
    let onUpdated: () -> Void
    var body: some View {
        Section {
            Text("标签自动保存并确认，无需逐条处理。人物与宠物仍可核对；所有结果都保留记录。")
                .font(.subheadline).foregroundStyle(.secondary)
            NavigationLink("自动整理设置") { NativeOrganizationSettingsView(session: store.session) }
            Picker("记录类型", selection: $store.organizationKind) {
                Text("全部类型").tag(""); Text("标签").tag("tags"); Text("人物").tag("face"); Text("宠物").tag("pet")
            }.disabled(store.busy)
            if let queue = store.organizationQueue { LabeledContent("待核对人物与宠物", value: "\(queue.pending) 条") }
            Button("立即整理一批") { Task { await store.organizeBatch(); onUpdated() } }
                .disabled(store.busy || store.organizationSettings?.tags_enabled != true)
        } header: { Text("自动整理记录") }
        if let queue = store.organizationQueue {
            if !queue.errors.isEmpty {
                Section("分析未完成") {
                    ForEach(queue.errors, id: \.media_id) { item in Text("#\(item.media_id) · \(item.message)").font(.caption).foregroundStyle(.red) }
                    Button("重试失败影像") { Task { await store.organizeBatch(retry: true); onUpdated() } }.disabled(store.busy)
                }
            }
            ForEach(queue.items) { entry in
                Section {
                    NativeOrganizationReviewCard(entry: entry, profiles: store.profiles, busy: store.busy,
                        preview: { preview(entry.media, entry.frame_seconds) },
                        review: { action, remember, tags, person in Task {
                            await store.reviewOrganization(entry, action: action, remember: remember, tags: tags, childID: person)
                            onUpdated()
                        } })
                        .id("\(entry.id)-\(entry.updated_at)")
                }
            }
            if queue.items.isEmpty && !store.busy { Section { Text("当前没有待审核记录，可查看全部记录。").foregroundStyle(.secondary) } }
        }
    }
}

private struct NativeOrganizationReviewCard: View {
    let entry: MemoryOrganizationEntry
    let profiles: [UploadProfile]
    let busy: Bool
    let preview: () -> Void
    let review: (String, Bool, [String: String?], Int) -> Void
    @State private var labels: [String: String]
    @State private var selected: Set<String>
    @State private var person: Int
    @State private var remember = false
    init(entry: MemoryOrganizationEntry, profiles: [UploadProfile], busy: Bool, preview: @escaping () -> Void,
         review: @escaping (String, Bool, [String: String?], Int) -> Void) {
        self.entry = entry; self.profiles = profiles; self.busy = busy; self.preview = preview; self.review = review
        _labels = State(initialValue: Dictionary(uniqueKeysWithValues: (entry.proposed.tags ?? []).map { tag in (tag, entry.current.decisions?[tag].flatMap { $0 } ?? tag) }))
        _selected = State(initialValue: Set((entry.proposed.tags ?? []).filter { tag in
            if let decisions = entry.current.decisions { return decisions[tag].flatMap { $0 } != nil }
            return entry.status == "pending" || (entry.current.tags ?? []).contains(tag)
        }))
        _person = State(initialValue: entry.current.child_id ?? 0)
    }
    private func name(_ id: Int?) -> String {
        guard let id else { return "未关联" }
        return profiles.first { $0.id == id }?.name ?? entry.names[String(id)] ?? "#\(id)"
    }
    private func submit(_ action: String) {
        let decisions: [String: String?] = Dictionary(uniqueKeysWithValues: (entry.proposed.tags ?? []).map { ($0, selected.contains($0) ? labels[$0] : nil) })
        review(action, remember, decisions, person)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(entry.title).font(.headline); Spacer(); Text(MemoryOrganizationEntry.statusLabel(entry.status)).font(.caption).foregroundStyle(.secondary) }
            Text(entry.media.day).font(.caption).foregroundStyle(.secondary)
            Button(action: preview) {
                HStack {
                    if !entry.thumbnail.isEmpty { MemoryReviewThumbnail(source: entry.thumbnail) }
                    Label("查看来源照片或视频", systemImage: "photo.on.rectangle")
                    if let seconds = entry.frame_seconds { Text("\(seconds, specifier: "%.1f") 秒").font(.caption) }
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(NativeTheme.accent).disabled(busy)
            if entry.kind == "tags" { tagFields }
            else {
                Text("\(name(entry.before.child_id)) → \(name(entry.proposed.child_id))")
                if let reason = entry.evidence.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if let score = entry.evidence.similarity { Text("相似度 \(score, specifier: "%.2f")").font(.caption).foregroundStyle(.secondary) }
                Picker("修改关联人物", selection: $person) {
                    Text("未关联").tag(0)
                    ForEach(profiles.filter { entry.kind == "pet" ? $0.profile_type == "pet" && $0.species == "狗" : $0.profile_type != "pet" }) { Text($0.name).tag($0.id) }
                }.disabled(busy)
            }
            if entry.status == "superseded" {
                Text("此记录已有后续修改，可打开来源查看当前结果。").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("以后按这次处理", isOn: $remember).disabled(busy)
                ViewThatFits {
                    HStack { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }
            }
            DisclosureGroup("处理记录与依据") {
                VStack(alignment: .leading, spacing: 12) {
                    if let description = entry.evidence.description { Text(description).font(.caption) }
                    ForEach(Array(entry.events.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(event.actor_name) · \(MemoryOrganizationEntry.statusLabel(event.action))").font(.caption.weight(.semibold))
                            Text(NativeAuditLabels.time(event.at)).font(.caption2).foregroundStyle(.secondary)
                            Text(event.value.tags.map { $0.isEmpty ? "未添加标签" : $0.joined(separator: "、") } ?? name(event.value.child_id)).font(.caption)
                            if event.value.remember == true { Text("已记住本次处理习惯").font(.caption).foregroundStyle(NativeTheme.accent) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.font(.subheadline)
        }.padding(.vertical, 6)
    }
    @ViewBuilder private var tagFields: some View {
        Text("原有标签 · " + ((entry.before.tags ?? []).isEmpty ? "无" : entry.before.tags!.joined(separator: "、"))).font(.caption).foregroundStyle(.secondary)
        ForEach(entry.proposed.tags ?? [], id: \.self) { tag in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(tag, isOn: Binding(get: { selected.contains(tag) }, set: { if $0 { selected.insert(tag) } else { selected.remove(tag) } })).disabled(busy)
                TextField("修改标签", text: Binding(get: { labels[tag] ?? tag }, set: { labels[tag] = $0 })).disabled(busy || !selected.contains(tag))
                if let item = entry.evidence.tags?.first(where: { $0.name == tag }) { Text(item.evidence).font(.caption).foregroundStyle(.secondary) }
            }
        }
        Text("当前影像标签 · " + ((entry.media.tags ?? []).isEmpty ? "无" : entry.media.tags!.joined(separator: "、"))).font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private var actions: some View {
        if entry.kind != "tags" {
            Button("保留结果") { submit("approve") }.buttonStyle(NativeActionStyle(kind: .primary))
                .disabled(busy || person != (entry.current.child_id ?? 0))
        }
        Button("保存修改") { submit("correct") }.buttonStyle(NativeActionStyle()).disabled(busy)
        Button("撤回这次结果", role: .destructive) { submit("reject") }.buttonStyle(NativeActionStyle()).disabled(busy)
    }
}

private struct NativeCurationView: View {
    @StateObject private var store: NativeCurationStore
    let onUpdated: () -> Void
    @State private var previewing: NativeTimelineItem?
    @State private var seconds: Double?
    @State private var choosingAlbums = false
    @State private var pendingAction: String?
    init(session: NativeSession, onUpdated: @escaping () -> Void) {
        _store = StateObject(wrappedValue: NativeCurationStore(session: session)); self.onUpdated = onUpdated
    }
    var body: some View {
        List {
            Section {
                Text("选中照片，再添加到家人或宠物相册。").font(.headline)
                Text("照片和视频仍保留在时间线，已有相册也会保留。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("查看", selection: $store.scope) {
                    Text("待整理").tag("unfiled")
                    Text("全部照片和视频").tag("all")
                    Text("已完成或暂不整理").tag("handled")
                }.disabled(store.busy || !store.selected.isEmpty)
                if let queue = store.queue {
                    Text("还有 \(queue.unfiled_media) 项待整理").font(.caption).foregroundStyle(.secondary)
                }
                NavigationLink {
                    NativeMemoryReviewView(session: store.session, onUpdated: onUpdated)
                } label: { Label("通过人脸确认家人和宠物", systemImage: "person.crop.rectangle") }
            }
            if store.busy { Section { ProgressView(store.reviewing ? "正在检查清晰度…" : "正在加载…") } }
            if !store.error.isEmpty {
                Section {
                    Text(store.error).foregroundStyle(.red)
                    Button("重新加载") { Task { await store.load() } }.disabled(store.busy)
                }
            }
            if !store.notice.isEmpty || store.undoToken != nil {
                Section {
                    if !store.notice.isEmpty { Label(store.notice, systemImage: "checkmark.circle").foregroundStyle(NativeTheme.accent) }
                    if store.undoToken != nil {
                        Button("撤销上次整理") { Task { await store.undo(); onUpdated() } }.disabled(store.busy)
                    }
                }
            }
            if !store.pageIDs.isEmpty {
                Section {
                    Button(store.pageIDs.allSatisfy { store.selected.contains($0) } ? "取消选择本页" : "选择本页全部") {
                        store.toggle(store.pageIDs)
                    }.disabled(store.busy)
                } footer: {
                    Text("按拍摄时间或重复内容分组，展开后可以逐项选择。")
                }
            }
            ForEach(store.queue?.items ?? []) { group in
                NativeCurationGroupCard(group: group, store: store) { item, representative in
                    seconds = representative ? item.quality?.representativeSeconds : nil; previewing = item.media
                }
            }
            if store.queue?.items.isEmpty == true && !store.busy && store.error.isEmpty {
                Section { Label("这里已整理好，可以切换范围查看其他照片。", systemImage: "checkmark.circle") }
            }
            if !store.history.isEmpty || store.queue?.next_cursor != nil {
                Section {
                    HStack {
                        Button("上一页") { Task { await store.page(next: false) } }.disabled(store.busy || store.history.isEmpty || !store.selected.isEmpty)
                        Spacer()
                        Button("下一页") { Task { await store.page(next: true) } }.disabled(store.busy || store.queue?.next_cursor == nil || !store.selected.isEmpty)
                    }
                    if !store.selected.isEmpty { Text("先处理或取消当前选择，再翻页。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(NativeTheme.background)
        .navigationTitle("整理到家人相册").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !store.selected.isEmpty { selectionBar } }
        .task { await store.load() }
        .onChange(of: store.scope) { _ in Task { await store.load(reset: true) } }
        .refreshable { if !store.busy { await store.load() } }
        .onDisappear { store.stopRequested = true }
        .nativeSheet(isPresented: $choosingAlbums) { albumSheet }
        .confirmationDialog(pendingAction == "done" ? "这些照片已经整理好了吗？" : "暂不整理这些照片？", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button(pendingAction == "done" ? "标记已整理" : "暂不整理") {
                let action = pendingAction ?? "ignore"; pendingAction = nil
                Task { await store.save(action: action); onUpdated() }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction == "done" ? "所选 \(store.selected.count) 项会移出待整理列表，不改变所属相册。可以撤销。" : "所选 \(store.selected.count) 项会移出待整理列表，照片仍在时间线和原相册中。可以撤销。")
        }
        .nativeSheet(item: $previewing) { media in
            NativeMediaDetail(session: store.session, initial: media, profiles: store.profiles, pagePosition: nil, previous: nil, next: nil,
                onSaved: { Task { await store.load(); onUpdated() } }, onDeleted: { previewing = nil; Task { await store.load(); onUpdated() } }, onLocate: nil, initialPlaybackSeconds: seconds)
        }
    }
    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text("已选 \(store.selected.count) 项").font(.subheadline.weight(.semibold))
                Spacer()
                Button("取消选择") { store.selected = []; store.selectedProfiles = [] }.disabled(store.busy)
                Menu {
                    Button("已经整理好") { pendingAction = "done" }
                    Button("暂不整理") { pendingAction = "ignore" }
                    Button("检查照片清晰度") { Task { await store.reviewQuality() } }
                        .disabled(store.queue?.quality_enabled != true || store.selected.count > 20)
                } label: { Label("更多", systemImage: "ellipsis.circle") }.disabled(store.busy)
            }.font(.subheadline)
            if store.reviewing {
                Button("停止后续检查") { store.stopRequested = true }
            } else {
                Button { choosingAlbums = true } label: { Text("下一步：选择相册").frame(maxWidth: .infinity) }
                    .buttonStyle(NativeActionStyle(kind: .primary)).disabled(store.busy)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(.bar)
    }
    private var albumSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("将 \(store.selected.count) 项照片和视频添加到哪些相册？").font(.headline)
                    Text("可以选择多个家人或宠物。已有相册不会被替换。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("选择相册") {
                    ForEach(store.profiles) { profile in
                        Toggle(profile.name, isOn: Binding(get: { store.selectedProfiles.contains(profile.id) }, set: { value in
                            if value { store.selectedProfiles.insert(profile.id) } else { store.selectedProfiles.remove(profile.id) }
                        })).disabled(store.busy)
                    }
                    if store.profiles.isEmpty { Text("还没有家人或宠物档案，请先到“家人”页面添加。").foregroundStyle(.secondary) }
                }
                if !store.error.isEmpty { Section { Text(store.error).foregroundStyle(.red) } }
                if !store.selectedProfiles.isEmpty {
                    Section("保存后") {
                        Text("\(store.selected.count) 项将加入：\(store.selectedAlbumNames)。")
                        Text("同时标记为已整理。返回后可撤销这次操作。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("选择相册").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回选照片") { choosingAlbums = false }.disabled(store.busy) } }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { if await store.save(action: "add") { choosingAlbums = false; onUpdated() } }
                } label: {
                    HStack { if store.busy { ProgressView() }; Text(store.busy ? "正在保存…" : "添加到相册") }.frame(maxWidth: .infinity)
                }.buttonStyle(NativeActionStyle(kind: .primary))
                    .disabled(store.busy || store.selectedProfiles.isEmpty || store.selected.isEmpty)
                    .padding(16).background(.bar)
            }
        }.nativeInteractiveDismissDisabled(store.busy)
    }
}
private struct NativeCurationGroupCard: View {
    let group: NativeCurationGroup
    @ObservedObject var store: NativeCurationStore
    let preview: (NativeCurationItem, Bool) -> Void
    @State private var expanded = false
    private var selectedCount: Int { group.items.filter { store.selected.contains($0.id) }.count }
    var body: some View {
        Section {
            if group.items.count > 1 {
                Button { store.toggle(group.items.map(\.id)) } label: {
                    Label("\(group.label) · \(group.items.count) 项 · 已选 \(selectedCount)", systemImage: selectedCount == group.items.count ? "checkmark.square.fill" : selectedCount == 0 ? "square" : "minus.square.fill")
                }.disabled(store.busy)
                Button(expanded ? "收起照片" : "展开全部 \(group.items.count) 项") { expanded.toggle() }
            }
            ForEach(expanded ? group.items : Array(group.items.prefix(1))) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Button { preview(item, item.quality != nil) } label: {
                        if let quality = item.quality, let raw = quality.thumbnail.split(separator: ",").last, let data = Data(base64Encoded: String(raw)), let image = UIImage(data: data) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                        } else if let file = item.media.primary {
                            NativeMediaImage(session: store.session, mediaID: item.id, fileID: file.id).frame(height: 180).clipped()
                        } else {
                            Image(systemName: "photo").font(.largeTitle).frame(maxWidth: .infinity).frame(height: 100).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("预览\(item.media.label)")
                    Toggle(item.media.title?.isEmpty == false ? item.media.title! : item.media.day + (item.media.media_type == "video" ? " 视频" : " 照片"), isOn: Binding(get: { store.selected.contains(item.id) }, set: { _ in store.toggle([item.id]) })).disabled(store.busy)
                    let names = (item.media.child_ids ?? []).compactMap { id in store.profiles.first { $0.id == id }?.name }
                    Text(names.isEmpty ? "还未加入家人相册" : "所在相册：" + names.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    if let quality = item.quality {
                        DisclosureGroup("清晰度检查结果") {
                            ForEach(quality.frames) { frame in Text("清晰度 \(frame.clarity)/5 · \(frame.reason)").font(.caption).foregroundStyle(.secondary) }
                            Button("查看原照片或视频") { preview(item, false) }
                        }
                    }
                }.padding(.vertical, 6)
            }
        }
    }
}

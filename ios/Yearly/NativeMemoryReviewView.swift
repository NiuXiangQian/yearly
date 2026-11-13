import SwiftUI

struct NativeMemoryReviewView: View {
    @StateObject private var store: NativeMemoryReviewStore
    let onUpdated: () -> Void
    @State private var interviewing: NativeTimelineItem?
    @State private var previewing: NativeTimelineItem?
    @State private var previewSeconds: Double?
    init(session: NativeSession, mediaID: Int? = nil, tab: NativeMemoryReviewStore.Tab = .faces, onUpdated: @escaping () -> Void = {}) {
        _store = StateObject(wrappedValue: NativeMemoryReviewStore(session: session, mediaID: mediaID, tab: tab))
        self.onUpdated = onUpdated
    }
    var body: some View {
        Group {
            if store.session.isAdmin {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("认出家人，留下故事").font(.title2.bold())
                            Text("确认人物与宠物，根据画面和补充信息生成标签。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                        Toggle(store.tab == .organization ? "全部记录，可复审修改" : "包含已处理，可修改确认结果", isOn: $store.includeReviewed).disabled(store.busy)
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
                    case .memories: memorySections
                    case .organization:
                        NativeOrganizationReviewSections(store: store, preview: { media, seconds in previewSeconds = seconds; previewing = media }, onUpdated: onUpdated)
                    }
                    Section {
                        HStack {
                            Button("上一页") { Task { await store.page(next: false) } }.disabled(store.history.isEmpty || store.busy)
                            Spacer()
                            Button("下一页") { Task { await store.page(next: true) } }.disabled(store.nextCursor == nil || store.busy)
                        }.frame(minHeight: 44)
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(NativeTheme.background)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Picker("整理内容", selection: $store.tab) {
                        ForEach(NativeMemoryReviewStore.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).disabled(store.busy)
                        .padding(.horizontal, 16).padding(.vertical, 10).background(NativeTheme.background)
                }
                .refreshable { if !store.busy { await store.load() } }
                .task(id: "\(store.tab)-\(store.includeReviewed)-\(store.organizationKind)") { await store.load(reset: true) }
            } else { Text("AI 整理需要管理员权限。").padding() }
        }
        .navigationTitle("AI 整理").navigationBarTitleDisplayMode(.inline)
        .alert("已自动整理相似人脸", isPresented: Binding(get: { store.autoLinkedCount > 0 }, set: { if !$0 { store.autoLinkedCount = 0 } })) {
            Button("知道了", role: .cancel) { store.autoLinkedCount = 0 }
        } message: { Text("已将另外 \(store.autoLinkedCount) 张明确匹配的人脸关联到对应人物，可在已处理项中查看和修改。") }
        .nativeSheet(item: $previewing) { media in
            NativeMediaDetail(session: store.session, initial: media, profiles: store.profiles, pagePosition: nil, previous: nil, next: nil,
                onSaved: { Task { await store.load(); onUpdated() } },
                onDeleted: { previewing = nil; Task { await store.load(); onUpdated() } }, onLocate: nil, initialPlaybackSeconds: previewSeconds)
        }
        .nativeSheet(item: $interviewing, onDismiss: { Task { await store.load(); onUpdated() } }) { media in
            NativeMemoryInterviewView(session: store.session, media: media, onUpdated: onUpdated)
        }
    }
    @ViewBuilder private var subjectSections: some View {
        if let queue = store.faces {
            Section {
                LabeledContent("待确认人物", value: "\(queue.pending_faces) 张脸")
                LabeledContent("识别到宠物 · 待确认", value: "\(store.pets?.pending_pets ?? 0) 条")
                if !queue.enabled || !queue.ready { Text(queue.message).font(.caption).foregroundStyle(.secondary) }
                Button(store.mediaID == nil ? "分析下一批人物影像" : "查找本影像中的人脸", systemImage: "viewfinder") {
                    Task { await store.analyzeNext(); onUpdated() }
                }.disabled(store.busy || !queue.enabled || !queue.ready || (store.mediaID == nil && queue.unanalysed_photos == 0))
                Button(store.mediaID == nil ? "补充宠物识别" : "识别本影像中的宠物", systemImage: "pawprint") {
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
            if store.subjects.isEmpty && !store.busy { Section { Text("当前没有待确认的人物或宠物，可查看已处理项或继续分析影像。").foregroundStyle(.secondary) } }
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
            Button("智能打标签", systemImage: "tag") { interviewing = media }.disabled(store.busy)
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
            Button("智能打标签", systemImage: "tag") { interviewing = media }.disabled(store.busy)
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
    private var memorySections: some View {
        Section {
            Text("根据已识别的人物、宠物和画面内容推荐标签。可以补充信息以完善建议，确认后保存标签与小记。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(store.memories) { media in
                Button { interviewing = media } label: {
                    HStack(spacing: 14) {
                        if let file = media.primary {
                            NativeMediaImage(session: store.session, mediaID: media.id, fileID: file.id).frame(width: 72, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(media.title.flatMap { $0.isEmpty ? nil : $0 } ?? media.day).font(.headline).foregroundStyle(.primary)
                            Text(media.interview_status == "completed" ? "已保存，可继续补充" : media.interview_status == "draft" ? "继续完善标签" : "识别场景 · 推荐标签").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
            if store.memories.isEmpty && !store.busy { Text("当前回忆已处理完成，可勾选“包含已处理”继续补充。").foregroundStyle(.secondary) }
        } header: { Text("智能打标签") }
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

struct NativeMemoryInterviewView: View {
    @StateObject private var store: NativeMemoryInterviewStore
    let media: NativeTimelineItem
    let onUpdated: () -> Void
    @NativeDismiss private var dismiss
    @State private var previewing = false
    @State private var reviewingFaces = false
    @State private var closing = false
    init(session: NativeSession, media: NativeTimelineItem, onUpdated: @escaping () -> Void = {}) {
        _store = StateObject(wrappedValue: NativeMemoryInterviewStore(session: session, mediaID: media.id))
        self.media = media; self.onUpdated = onUpdated
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let file = media.primary {
                        NativeMediaImage(session: store.session, mediaID: media.id, fileID: file.id, purpose: "preview")
                            .frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(media.day).font(.caption).foregroundStyle(.secondary)
                    Button("查看完整照片或视频", systemImage: "play.rectangle") { previewing = true }
                }
                if store.busy { Section { ProgressView("正在整理这份回忆…") } }
                if !store.error.isEmpty { Section {
                    Text(store.error).foregroundStyle(.red)
                    if store.state == nil { Button("重新加载") { Task { await store.load() } }.disabled(store.busy) }
                } }
                if !store.notice.isEmpty { Section { Text(store.notice).foregroundStyle(NativeTheme.accent) } }
                if let state = store.state {
                    identitySection(state)
                    if !state.description.isEmpty { Section { DisclosureGroup("已有画面描述") { Text(state.description).font(.subheadline) } } }
                    Section {
                        if state.outdated { Text("人物或影像有更新，请更新提问与标签建议。").font(.caption).foregroundStyle(.secondary) }
                        if state.suggestions == nil || state.outdated || state.status == "completed" {
                            Button(state.suggestions == nil ? "生成推荐标签" : "更新标签建议") { Task { await store.prepare() } }
                                .buttonStyle(NativeActionStyle(kind: .primary)).disabled(store.busy)
                        }
                    }
                    if let suggestions = state.suggestions {
                        conversation(state, suggestions)
                        tagSection(state, suggestions)
                        Section {
                            if let remark = state.media.remark, !remark.isEmpty { DisclosureGroup("原有小记") { Text(remark) } }
                            TextField("你的回答作为草稿，可修改后保存", text: Binding(get: { store.addition }, set: { store.addition = $0; store.noteEdited = true }), axis: .vertical)
                                .lineLimit(3...12).disabled(store.busy)
                            if store.noteEdited && suggestions.story != store.addition {
                                Button("使用最新回答的小记草稿") { store.addition = suggestions.story; store.noteEdited = false }.disabled(store.busy)
                            }
                            Text("补充内容将追加保存，原有小记与人物关联保留。").font(.caption).foregroundStyle(.secondary)
                            Button("保存标签与小记") { Task { await store.apply(); onUpdated() } }
                                .buttonStyle(NativeActionStyle(kind: .primary)).disabled(store.busy || state.status == "completed" || store.addition.count > 4000)
                        } header: { Text("补充到时光小记") }
                    }
                    Section { Text("智能打标签与宠物分析使用站点 AI 额度，人脸匹配在服务端本地运行。").font(.caption).foregroundStyle(.secondary) }
                }
            }.scrollContentBackground(.hidden).background(NativeTheme.background)
                .navigationTitle("智能打标签").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { if store.hasEdits { closing = true } else { dismiss() } }.disabled(store.busy)
                } }
                .confirmationDialog("还有未保存的编辑", isPresented: $closing, titleVisibility: .visible) {
                    Button("继续编辑", role: .cancel) {}
                    Button("放弃编辑并关闭", role: .destructive) { dismiss() }
                }
                .task { await store.load() }
        }
        .interactiveDismissDisabled(store.busy || store.hasEdits)
        .nativeSheet(isPresented: $previewing) {
            NativeMediaDetail(session: store.session, initial: media, profiles: store.profiles, pagePosition: nil, previous: nil, next: nil,
                onSaved: { Task { await store.load(); onUpdated() } }, onDeleted: { dismiss(); onUpdated() }, onLocate: nil)
        }
        .nativeSheet(isPresented: $reviewingFaces, onDismiss: { Task { await store.load(); onUpdated() } }) {
            reviewSheet()
        }
    }
    private func reviewSheet() -> some View {
        NavigationStack {
            NativeMemoryReviewView(session: store.session, mediaID: media.id, onUpdated: onUpdated)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回智能打标签") { reviewingFaces = false } } }
        }
    }
    private func identitySection(_ state: MemoryInterviewState) -> some View {
        Section {
            if !state.confirmed_people.isEmpty { LabeledContent("已确认人物", value: state.confirmed_people.joined(separator: "、")) }
            if let pets = state.confirmed_pets, !pets.isEmpty { LabeledContent("已确认宠物", value: pets.joined(separator: "、")) }
            ForEach(state.identity_questions, id: \.face_id) { Text($0.question).font(.subheadline) }
            Button("确认这份影像中的人物与宠物", systemImage: "person.crop.rectangle") { reviewingFaces = true }.disabled(store.busy)
            DisclosureGroup("补充关联人物与宠物") {
                ForEach(store.profiles) { profile in
                    Toggle(profile.label, isOn: Binding(get: { store.people.contains(profile.id) }, set: { enabled in
                        store.people.removeAll { $0 == profile.id }; if enabled { store.people.append(profile.id) }; store.peopleEdited = true
                    })).disabled(store.busy)
                }
                Button("保存人物关联") { Task { await store.savePeople(); onUpdated() } }.disabled(store.busy || !store.peopleEdited)
                Text("整张影像关联不能代替每张脸的身份确认。").font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("这里面都有谁？") }
    }
    private func conversation(_ state: MemoryInterviewState, _ suggestions: MemoryInterviewState.Suggestions) -> some View {
        Section {
            ForEach(Array(state.messages.enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.role == "user" ? "你的补充" : "标签助手").font(.caption.weight(.semibold)).foregroundStyle(NativeTheme.accent)
                    Text(message.content).textSelection(.enabled)
                }.padding(.vertical, 5)
            }
            ForEach(suggestions.options, id: \.self) { option in Button(option) { store.answer = option }.disabled(store.busy) }
            TextField("补充场景、活动等信息，帮助完善标签", text: $store.answer, axis: .vertical).lineLimit(3...10).disabled(store.busy)
            Button("补充信息并更新标签") { Task { await store.reply() } }
                .buttonStyle(NativeActionStyle()).disabled(store.busy || store.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.answer.count > 2000)
        } header: { Text("标签补充信息") }
    }
    private func tagSection(_ state: MemoryInterviewState, _ suggestions: MemoryInterviewState.Suggestions) -> some View {
        Section {
            ForEach(suggestions.tags) { tag in
                Toggle(isOn: Binding(get: { store.tags.contains(tag.name) }, set: { enabled in
                    store.tags.removeAll { $0 == tag.name }; if enabled { store.tags.append(tag.name) }; store.tagsEdited = true
                })) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tag.name)
                        Text("\(tag.sourceLabel) · \(tag.evidence)").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(store.busy)
            }
            if suggestions.tags.isEmpty { Text("现有信息不足以推荐新标签，可继续补充或手动添加。").font(.caption).foregroundStyle(.secondary) }
            TextField("补充标签", text: $store.extraTag).disabled(store.busy)
            Button("添加标签") { store.addTag() }.disabled(store.busy || store.extraTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.extraTag.count > 80)
            ForEach(store.tags.filter { selected in !suggestions.tags.contains { $0.name == selected } }, id: \.self) { tag in
                HStack { Text(tag); Spacer(); Button("移除") { store.tags.removeAll { $0 == tag }; store.tagsEdited = true }.disabled(store.busy) }
            }
            if let tags = state.media.tags, !tags.isEmpty { Text("已有标签 · " + tags.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("推荐标签") } footer: { Text("勾选要保存的标签，每项显示推荐依据。") }
    }
}

private struct NativeOrganizationReviewSections: View {
    @ObservedObject var store: NativeMemoryReviewStore
    let preview: (NativeTimelineItem, Double?) -> Void
    let onUpdated: () -> Void
    var body: some View {
        Section {
            Text("标签自动写入，明确匹配的人物自动关联。查看来源后可保留、修改或撤回；所有处理都有记录。")
                .font(.subheadline).foregroundStyle(.secondary)
            if store.organizationSettings != nil {
                DisclosureGroup("自动整理与我的习惯") {
                    Toggle("自动打标签并进入审核列表", isOn: Binding(get: { store.organizationSettings?.tags_enabled == true }, set: { store.organizationSettings?.tags_enabled = $0 })).disabled(store.busy)
                    Toggle("自动关联明确匹配的人物与宠物并记录", isOn: Binding(get: { store.organizationSettings?.people_enabled == true }, set: { store.organizationSettings?.people_enabled = $0 })).disabled(store.busy)
                    Text("审核时勾选“以后按这次处理”，记住标签用词或人物处理方式。自动通过的结果仍可复审。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach((store.organizationSettings?.tag_rules.keys.sorted() ?? []), id: \.self) { source in
                        if let rule = store.organizationSettings?.tag_rules[source] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(source) → \(rule.mode == "skip" ? "不再添加" : rule.mode == "manual" ? "先审核" : "自动通过") \(rule.target)").font(.subheadline)
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
                    Button("保存整理习惯") { Task { await store.saveOrganizationSettings() } }.disabled(store.busy)
                }
            }
            Picker("记录类型", selection: $store.organizationKind) {
                Text("全部类型").tag(""); Text("标签").tag("tags"); Text("人物").tag("face"); Text("宠物").tag("pet")
            }.disabled(store.busy)
            if let queue = store.organizationQueue { LabeledContent("待审核", value: "\(queue.pending) 条") }
            Button("立即整理一批") { Task { await store.organizeBatch(); onUpdated() } }
                .disabled(store.busy || store.organizationSettings?.tags_enabled != true)
        } header: { Text("自动整理审核") }
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
        Button("保留结果") { submit("approve") }.buttonStyle(NativeActionStyle(kind: .primary))
            .disabled(busy || (entry.kind != "tags" && person != (entry.current.child_id ?? 0)))
        Button("保存修改") { submit("correct") }.buttonStyle(NativeActionStyle()).disabled(busy)
        Button("撤回这次结果", role: .destructive) { submit("reject") }.buttonStyle(NativeActionStyle()).disabled(busy)
    }
}

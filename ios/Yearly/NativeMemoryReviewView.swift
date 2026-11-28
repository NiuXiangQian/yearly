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
                Section("人物与宠物") {
                    NavigationLink {
                        NativeMemoryReviewView(session: session, onUpdated: onUpdated)
                    } label: {
                        NativeOrganizationTaskLabel(title: "确认人物与宠物",
                            detail: "一起核对相似影像，纠正识别结果", symbol: "person.crop.circle.badge.checkmark")
                    }
                }
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
    @State private var groupSelections: [Int: Set<Int>] = [:]
    @State private var groupPeople: [Int: Int] = [:]
    @State private var selecting = false
    @State private var batchProfile = 0
    @AccessibilityFocusState private var focusNotice: Bool
    init(session: NativeSession, mediaID: Int? = nil, tab: NativeMemoryReviewStore.Tab = .faces, onUpdated: @escaping () -> Void = {}) {
        _store = StateObject(wrappedValue: NativeMemoryReviewStore(session: session, mediaID: mediaID, tab: tab))
        self.onUpdated = onUpdated
    }
    var body: some View {
        Group {
            if store.session.isAdmin {
                List {
                    if !selecting {
                        Section {
                            if store.tab == .organization {
                                Text("查看、修改或撤回自动整理结果。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Picker("识别记录", selection: $store.includeReviewed) {
                                Text("待确认").tag(false)
                                Text("全部记录").tag(true)
                            }.pickerStyle(.segmented).disabled(store.busy)
                            if store.mediaID != nil { Text("仅查看当前影像的识别结果").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if store.busy { Section { ProgressView("正在处理，请稍候…") } }
                    if !store.error.isEmpty {
                        Section {
                            Text(store.error).foregroundStyle(.red)
                            Button("重新加载") { Task { await store.load() } }.disabled(store.busy)
                        }
                    }
                    if !store.notice.isEmpty {
                        Section {
                            Label(store.notice, systemImage: "checkmark.circle")
                                .foregroundStyle(.primary).accessibilityFocused($focusNotice)
                        }
                    }
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
        .onChange(of: store.notice) { if !$0.isEmpty { focusNotice = true } }
        .navigationTitle(store.tab.rawValue).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.session.isAdmin && store.tab == .faces && !store.includeReviewed &&
                (selecting || store.subjects.contains(where: \.canConfirmInBatch)) {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(selecting ? "取消多选" : "多选") {
                        if selecting { endBatchSelection() }
                        else { selecting = true }
                    }.disabled(store.busy)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { batchActions }
        }
        .onChange(of: store.batchSelection.count) { if $0 == 0 { batchProfile = 0 } }
        .nativeSheet(item: $previewing) { media in
            NativeMediaDetail(session: store.session, initial: media, profiles: store.profiles, pagePosition: nil, previous: nil, next: nil,
                onSaved: { Task { await store.load(); onUpdated() } },
                onDeleted: { previewing = nil; Task { await store.load(); onUpdated() } }, onLocate: nil, initialPlaybackSeconds: previewSeconds)
        }
    }
    @ViewBuilder private var subjectSections: some View {
        if let queue = store.faces {
            if !selecting {
                Section {
                    Text("\(queue.pending_faces) 张人脸 · \(store.pets?.pending_pets ?? 0) 条宠物记录待确认")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !queue.enabled || !queue.ready { Text(queue.message).font(.caption).foregroundStyle(.secondary) }
                    if store.mediaID != nil || store.subjects.isEmpty {
                        analysisActions(queue)
                    } else {
                        Menu {
                            analysisActions(queue)
                        } label: {
                            Label("查找更多", systemImage: "viewfinder")
                                .frame(minHeight: 44)
                        }.accessibilityLabel("查找更多人物与宠物")
                    }
                }
            }
            if selecting {
                let kind = store.batchSelection.first?.kind
                let available = store.subjects.filter { $0.canConfirmInBatch && (kind == nil || $0.kind == kind) }
                ForEach(available) { batchRow($0) }
                if available.isEmpty && !store.busy {
                    Text(kind == nil ? "本页没有可勾选的记录" : "本页没有可勾选的同类记录")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(store.subjects) { subject in
                    switch subject {
                    case .face(let face, let media):
                        if let groupID = face.review_group_id, let group = store.faceGroups[groupID] {
                            if face.id == groupID { Section { faceGroup(group, id: groupID) } }
                        } else {
                            Section { faceRow(face, media) }
                        }
                    case .pet(let dog, let media):
                        Section { petRow(dog, media) }
                    }
                }
            }
            if !selecting && store.subjects.isEmpty && !store.busy {
                Section {
                    Label(store.includeReviewed ? "还没有识别记录" : "暂时没有待确认的影像", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
    }

    private var batchActions: some View {
        let count = store.batchSelection.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(count > 0 ? "已选 \(count) 项" : "勾选属于同一人物或宠物的记录")
                .font(.subheadline).foregroundStyle(.secondary)
            if count > 0 {
                Picker(store.batchSelection.first?.kind == .pet ? "关联宠物" : "关联人物", selection: $batchProfile) {
                    Text("请选择").tag(0)
                    ForEach(store.batchProfiles) { profile in
                        Text(profile.nickname.isEmpty ? profile.name : profile.nickname).tag(profile.id)
                    }
                }
                .frame(minHeight: 44)
                .disabled(store.busy)
                Button {
                    Task {
                        if await store.confirmSelected(childID: batchProfile) {
                            endBatchSelection()
                            onUpdated()
                        }
                    }
                } label: {
                    Label("确认 \(count) 项", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(NativeActionStyle(kind: .primary))
                .disabled(store.busy || !store.batchProfiles.contains { $0.id == batchProfile })
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func endBatchSelection() {
        store.clearBatchSelection()
        selecting = false
        batchProfile = 0
    }

    @ViewBuilder private func batchRow(_ subject: MemoryReviewSubject) -> some View {
        switch subject {
        case .face(let face, let media):
            batchRow(subject, media: media, image: face.thumbnail, seconds: face.frame_seconds,
                     candidate: face.candidates.first?.name)
        case .pet(let dog, let media):
            batchRow(subject, media: media, image: dog.thumbnail, seconds: dog.frame_seconds,
                     candidate: dog.candidates.first?.name)
        }
    }

    private func batchRow(_ subject: MemoryReviewSubject, media: NativeTimelineItem, image: String,
                          seconds: Double?, candidate: String?) -> some View {
        let selected = store.isBatchSelected(subject)
        let kind = subject.kind == .pet ? "宠物" : "人物"
        return HStack(spacing: 12) {
            Button {
                store.toggleBatchSelection(subject)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? NativeTheme.accent : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.map { "可能是 \($0)" } ?? "待确认\(kind)").foregroundStyle(.primary)
                        Text(media.day).font(.caption).foregroundStyle(.secondary)
                        if let seconds { Text("视频 \(seconds, specifier: "%.1f") 秒").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(selected ? "已选中" : "未选中")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(!store.canToggleBatchSelection(subject))
            Button {
                previewSeconds = seconds; previewing = media
            } label: {
                MemoryReviewThumbnail(source: image, width: 46, height: 50)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(media.media_type == "video" ? "查看来源视频" : "查看来源照片")
            .disabled(store.busy)
        }.padding(.vertical, 4)
    }

    @ViewBuilder private func analysisActions(_ queue: MemoryFaceQueue) -> some View {
        Button(store.mediaID == nil ? "查找更多人物" : "查找本影像中的人脸", systemImage: "viewfinder") {
            Task { await store.analyzeNext(); onUpdated() }
        }.disabled(store.busy || !queue.enabled || !queue.ready || (store.mediaID == nil && queue.unanalysed_media == 0))
        if store.mediaID != nil {
            Button("补查漏掉的人脸", systemImage: "person.crop.rectangle") {
                Task { await store.analyzeNext(refresh: true, detailedPhoto: true); onUpdated() }
            }.disabled(store.busy || !queue.enabled || !queue.ready)
        }
        Button(store.mediaID == nil ? "查找更多宠物" : "识别本影像中的宠物", systemImage: "pawprint") {
            Task { await store.analyzeNext(pets: true); onUpdated() }
        }.disabled(store.busy || (store.mediaID == nil && store.pets?.unanalysed_media == 0))
    }

    private func faceGroup(_ faces: [MemoryReviewFace], id: Int) -> some View {
        let all = Set(faces.map(\.id))
        let selected = (groupSelections[id] ?? all).intersection(all)
        let person = groupPeople[id, default: 0]
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("只保留属于同一个人的影像，再选择人物。")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(faces) { face in
                    if let media = face.media {
                        HStack(spacing: 12) {
                            Button {
                                var next = selected
                                if !next.insert(face.id).inserted { next.remove(face.id) }
                                groupSelections[id] = next
                            } label: {
                                Label(media.day, systemImage: selected.contains(face.id) ? "checkmark.circle.fill" : "circle")
                                    .frame(minHeight: 44)
                            }.buttonStyle(.borderless)
                                .accessibilityValue(selected.contains(face.id) ? "已选中" : "未选中")
                                .accessibilityAddTraits(selected.contains(face.id) ? .isSelected : [])
                                .disabled(store.busy)
                            Spacer(minLength: 0)
                            Button {
                                previewSeconds = face.frame_seconds; previewing = media
                            } label: {
                                MemoryReviewThumbnail(source: face.thumbnail, width: 46, height: 50)
                            }.buttonStyle(.borderless).accessibilityLabel("预览 \(media.day) 的来源影像")
                        }
                    }
                }
                Picker("确认人物", selection: Binding(get: { person }, set: { groupPeople[id] = $0 })) {
                    Text("请选择").tag(0)
                    ForEach(store.people) { person in Text(person.nickname.isEmpty ? person.name : person.nickname).tag(person.id) }
                }.frame(minHeight: 44).disabled(store.busy)
                Button("确认 \(selected.count) 份影像") {
                    Task {
                        if await store.confirmFaceGroup(ids: selected, childID: person) {
                            groupSelections[id] = nil
                            groupPeople[id] = nil
                            onUpdated()
                        }
                    }
                }.buttonStyle(NativeActionStyle(kind: .primary))
                    .disabled(store.busy || selected.isEmpty || person == 0)
            }.padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("核对 \(faces.count) 份相似影像").font(.headline)
                if let candidate = faces.first?.candidates.first {
                    Text("可能是 \(candidate.name)").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(faces.prefix(3)) { face in
                        MemoryReviewThumbnail(source: face.thumbnail, width: 42, height: 46).accessibilityHidden(true)
                    }
                }.accessibilityHidden(true)
            }.padding(.vertical, 8)
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
            if let candidate = face.candidates.first, face.child_id == nil, !face.ignored {
                Button("这不是\(candidate.name)") {
                    Task {
                        if await store.confirm(face: face, mediaID: media.id, rejecting: candidate.child_id) { onUpdated() }
                    }
                }.buttonStyle(.borderless).frame(minHeight: 44).disabled(store.busy)
            }
            Picker("关联人物", selection: faceChoice(face)) {
                Text("待确认").tag(0)
                ForEach(store.people) { Text($0.name).tag($0.id) }
                Text("忽略这张脸").tag(-1)
            }.disabled(store.busy)
            Button(faceChoice(face).wrappedValue == -1 ? "忽略人脸" : "保存人物确认") {
                Task { if await store.confirm(face: face, mediaID: media.id) { onUpdated() } }
            }
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
    var width: CGFloat = 72
    var height: CGFloat = 86
    var body: some View {
        Group {
            if let raw = source.split(separator: ",").last, let data = Data(base64Encoded: String(raw)), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Image(systemName: "photo").resizable().scaledToFit().padding(16).foregroundStyle(.secondary) }
        }.frame(width: width, height: height).clipped().background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 8))
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
                NativeFormField(title: "修改标签") {
                    TextField("", text: Binding(get: { labels[tag] ?? tag }, set: { labels[tag] = $0 }))
                }
                .disabled(busy || !selected.contains(tag))
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

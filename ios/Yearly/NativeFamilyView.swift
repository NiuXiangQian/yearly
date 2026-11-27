import SwiftUI
import PhotosUI

private enum ProfileColor {
    static let fallback = "#bf775d"

    static func color(_ hex: String?) -> Color {
        let text = hex ?? fallback
        let rgb = text.hasPrefix("#") && text.count == 7 ? UInt32(text.dropFirst(), radix: 16) ?? 0xbf775d : 0xbf775d
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }

    static func hex(_ color: Color) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let rgb = [red, green, blue].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
    }
}

struct NativeFamilyView: View {
    @ObservedObject var store: NativeTimelineStore
    let showTimeline: (UploadProfile) -> Void
    let onProfileUpdated: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var auditing: UploadProfile?

    private var columns: [GridItem] {
        textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 144), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if store.profiles.isEmpty {
                        if store.profilesLoading {
                            ProgressView("正在读取家人资料…")
                                .frame(maxWidth: .infinity)
                        } else if store.profilesError.isEmpty {
                            Text("还没有家人或宠物资料。")
                                .foregroundStyle(NativeTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if !store.profilesError.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.profilesError).foregroundStyle(.red)
                            Button("重新加载") { Task { await store.loadProfiles(refresh: true) } }
                                .buttonStyle(NativeActionStyle(compact: true))
                        }
                    }
                    profileSection("人物", profiles: store.profiles.filter { !$0.isPet })
                    profileSection("宠物", profiles: store.profiles.filter(\.isPet))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .background(NativeTheme.background)
            .navigationTitle("家人与宠物")
            .navigationDestination(for: Int.self) { profileID in
                if let profile = store.profiles.first(where: { $0.id == profileID }) {
                    NativeFamilyDetail(profile: profile, session: store.session) {
                        showTimeline(profile)
                    } audit: {
                        auditing = profile
                    } onSaved: { updated in
                        if let index = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                            store.profiles[index] = updated
                            store.profiles.sort { ($0.sort_order ?? 0, $0.id) < ($1.sort_order ?? 0, $1.id) }
                        }
                        onProfileUpdated()
                    }
                } else {
                    Text("此档案已不可用。").foregroundStyle(NativeTheme.secondaryText)
                        .navigationTitle("家人资料")
                }
            }
            .refreshable { await store.loadProfiles(refresh: true) }
            .task { await store.loadProfiles(refresh: true) }
            .nativeSheet(item: $auditing) { profile in
                NavigationStack {
                    NativeAuditView(session: store.session, resourceType: "child", resourceID: String(profile.id))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { auditing = nil } } }
                }
            }
        }
    }

    @ViewBuilder
    private func profileSection(_ title: String, profiles: [UploadProfile]) -> some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(profiles) { profile in
                        NavigationLink(value: profile.id) {
                            VStack(alignment: .leading, spacing: 8) {
                                NativeFamilyAvatar(session: store.session, mediaID: profile.avatar_media_id,
                                                   name: profile.displayName, pet: profile.isPet, color: profile.portraitColor,
                                                   size: nil, cornerRadius: 16)
                                    .frame(maxWidth: textSize.isAccessibilitySize ? 240 : .infinity)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName).font(.headline).foregroundStyle(.primary)
                                    Text(profile.status == "archived" ? "已归档" : profile.portraitSubtitle)
                                        .font(.subheadline).foregroundStyle(NativeTheme.secondaryText)
                                }
                                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("打开档案详情")
                    }
                }
            }
        }
    }
}

private struct NativeFamilyDetail: View {
    let profile: UploadProfile
    @ObservedObject var session: NativeSession
    let showTimeline: () -> Void
    let audit: () -> Void
    let onSaved: (UploadProfile) -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var showingPortrait = false
    @State private var editing: UploadProfile?
    @State private var saved = false

    private var facts: [(title: String, value: String)] {
        let values: [(String, String?)] = [
            (profile.isPet ? "名字" : "姓名", profile.name == profile.displayName ? nil : profile.name),
            (profile.isPet ? "物种" : "家庭关系", profile.isPet ? profile.species : profile.relationship),
            ("品种", profile.isPet ? profile.breed : nil),
            ("性别", profile.gender),
            ("出生日期", profile.birthday),
            ("出生时刻", profile.birth_time),
        ]
        return values.compactMap { title, value in
            guard let value, !value.isEmpty else { return nil }
            return (title, value)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions

                if saved {
                    Label("资料已保存", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NativeTheme.secondaryText)
                }
                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("基本资料").font(.headline).accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(facts, id: \.title) { fact in
                                if fact.title != facts.first?.title { Divider().accessibilityHidden(true) }
                                factRow(fact.title, value: fact.value)
                                    .padding(.vertical, 12)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                if let description = profile.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("简介").font(.headline).accessibilityAddTraits(.isHeader)
                        Text(description).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .background(NativeTheme.background)
        .navigationTitle("档案详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: audit) {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("修改记录")
            }
        }
        .fullScreenCover(isPresented: $showingPortrait) {
            if let mediaID = profile.avatar_media_id {
                NativeFamilyAvatarViewer(session: session, mediaID: mediaID, name: profile.displayName)
            }
        }
        .sheet(item: $editing) { editingProfile in
            NativeFamilyEditor(session: session, profile: editingProfile) { updated in
                saved = true
                onSaved(updated)
            }
            .tint(NativeTheme.accent)
        }
    }

    private var actions: some View {
        let layout = textSize >= .xxxLarge
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if profile.editable(by: session.account) {
                Button {
                    saved = false
                    editing = profile
                } label: {
                    Label("编辑资料", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NativeActionStyle())
            }
            Button(action: showTimeline) {
                Label("查看时间线", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NativeActionStyle(kind: .primary))
        }
    }

    private func factRow(_ title: String, value: String) -> some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(title)
                .foregroundStyle(NativeTheme.secondaryText)
                .fixedSize(horizontal: !textSize.isAccessibilitySize, vertical: true)
            Text(value)
                .frame(maxWidth: .infinity, alignment: textSize.isAccessibilitySize ? .leading : .trailing)
                .multilineTextAlignment(textSize.isAccessibilitySize ? .leading : .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        VStack(spacing: 12) {
            if profile.avatar_media_id != nil {
                Button { showingPortrait = true } label: {
                    portrait.overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.78), in: Circle())
                            .padding(8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看\(profile.displayName)的头像")
            } else {
                portrait
            }
            VStack(spacing: 4) {
                Text(profile.displayName)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(profile.status == "archived" ? "\(profile.kindLabel) · 已归档" : profile.kindLabel)
                    .font(.subheadline)
                    .foregroundStyle(NativeTheme.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var portrait: some View {
        NativeFamilyAvatar(session: session, mediaID: profile.avatar_media_id, name: profile.displayName,
                           pet: profile.isPet, color: profile.portraitColor, size: 144, cornerRadius: 24)
    }
}

private extension UploadProfile {
    var displayName: String { nickname.isEmpty ? name : nickname }
    var isPet: Bool { profile_type == "pet" }
    var portraitColor: Color { ProfileColor.color(theme_color) }
    var kindLabel: String { isPet ? "宠物" : profile_type == "child" ? "孩子" : "人物" }

    var portraitSubtitle: String {
        let details = isPet ? [species, breed].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            : relationship ?? ""
        return details.isEmpty || details == displayName ? kindLabel : details
    }
}

private struct NativeFamilyEditor: View {
    @ObservedObject var session: NativeSession
    let profile: UploadProfile
    let onSaved: (UploadProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var nickname: String
    @State private var type: String
    @State private var relationship: String
    @State private var species: String
    @State private var breed: String
    @State private var gender: String
    @State private var customGender: Bool
    @State private var birthday: Date
    @State private var hasBirthday: Bool
    @State private var birthTime: Date
    @State private var birthSecond: Int
    @State private var hasBirthTime: Bool
    @State private var growth: Bool
    @State private var notes: String
    @State private var theme: String
    @State private var order: String
    @State private var status: String
    @State private var avatarID: Int?
    @State private var avatarDraft: NativeAvatarDraft?
    @State private var avatarSource: NativeAvatarDraft?
    @State private var croppingAvatar: NativeAvatarDraft?
    @State private var existingAvatarToCrop: Int?
    @State private var avatarKey = UUID()
    @State private var libraryPhoto: PhotosPickerItem?
    @State private var choosingExisting = false
    @State private var preparingAvatar = false
    @State private var avatarProgress: Double?
    @State private var saving = false
    @State private var error = ""

    private static let relationships = ["孩子", "爸爸", "妈妈", "爷爷", "奶奶", "外公", "外婆", "哥哥", "姐姐", "弟弟", "妹妹", "朋友"]
    private static let animals = ["猫", "狗", "兔子", "鸟", "鱼", "仓鼠", "乌龟"]
    private static let genders = ["", "男", "女", "其他"]

    init(session: NativeSession, profile: UploadProfile, onSaved: @escaping (UploadProfile) -> Void) {
        self.session = session
        self.profile = profile
        self.onSaved = onSaved
        _name = State(initialValue: profile.name)
        _nickname = State(initialValue: profile.nickname)
        _type = State(initialValue: profile.profile_type)
        _relationship = State(initialValue: profile.relationship ?? "")
        _species = State(initialValue: profile.species ?? "")
        _breed = State(initialValue: profile.breed ?? "")
        _gender = State(initialValue: profile.gender ?? "")
        _customGender = State(initialValue: !Self.genders.contains(profile.gender ?? ""))
        let date = profile.birthday.flatMap(NativeDay.date)
        _birthday = State(initialValue: date ?? .now)
        _hasBirthday = State(initialValue: date != nil)
        let clock = Self.clock(profile.birth_time)
        _birthTime = State(initialValue: clock ?? NativeLocalDateTime.date("2000-01-01T12:00:00")!)
        _birthSecond = State(initialValue: clock.flatMap { Int(NativeLocalDateTime.string($0).suffix(2)) } ?? 0)
        _hasBirthTime = State(initialValue: profile.birth_time != nil)
        _growth = State(initialValue: profile.growth_enabled ?? (profile.profile_type != "person"))
        _notes = State(initialValue: profile.description ?? "")
        _theme = State(initialValue: profile.theme_color ?? ProfileColor.fallback)
        _order = State(initialValue: String(profile.sort_order ?? 0))
        _status = State(initialValue: profile.status == "archived" ? "archived" : "active")
        _avatarID = State(initialValue: profile.avatar_media_id)
    }

    private var pet: Bool { type == "pet" }
    private var displayName: String { nickname.isEmpty ? name : nickname }
    private var displayColor: Color { ProfileColor.color(theme) }
    private var displayOrder: Int32? { Int32(order.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var genderChoice: Binding<String> {
        Binding(get: { customGender ? "custom" : gender }, set: { option in
            customGender = option == "custom"
            gender = customGender ? "" : option
        })
    }
    private var birthClock: String? {
        guard hasBirthTime else { return nil }
        let hourMinute = NativeLocalDateTime.string(birthTime).suffix(8).prefix(5)
        let clock = "\(hourMinute):\(String(format: "%02d", birthSecond))"
        if let original = Self.clock(profile.birth_time), NativeLocalDateTime.string(original).suffix(8) == clock {
            return profile.birth_time
        }
        return clock
    }
    private var validation: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写姓名。" }
        if [name, nickname, relationship, species, breed].contains(where: { $0.unicodeScalars.count > 80 }) {
            return "姓名、昵称、关系、物种和品种最多各 80 字。"
        }
        if type == "child" && !hasBirthday { return "孩子档案需要填写出生日期。" }
        if gender.unicodeScalars.count > 24 { return "自定义性别最多 24 字。" }
        if notes.unicodeScalars.count > 10_000 { return "档案介绍最多 10,000 字。" }
        if displayOrder == nil { return "请输入有效的整数显示顺序。" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                avatarSection
                Section("基本资料") {
                    field(pet ? "宠物名字" : "姓名", "必填", text: $name)
                    field("昵称", "选填", text: $nickname)
                    Picker("档案类型", selection: $type) {
                        Text("孩子").tag("child")
                        Text("人物").tag("person")
                        Text("宠物").tag("pet")
                    }
                    if pet {
                        field("物种", "例如：猫", text: $species)
                        choices("选择常见物种", options: Self.animals, value: $species)
                        field("品种", "例如：英短", text: $breed)
                    } else {
                        field("家庭关系", "例如：爸爸、外婆", text: $relationship)
                        choices("选择常见关系", options: Self.relationships, value: $relationship)
                    }
                    Picker("性别", selection: genderChoice) {
                        Text("暂不填写").tag("")
                        Text(pet ? "公" : "男").tag("男")
                        Text(pet ? "母" : "女").tag("女")
                        Text("其他").tag("其他")
                        Text("自定义").tag("custom")
                    }
                    if customGender { field("自定义性别", "选填", text: $gender) }
                }
                Section {
                    Toggle(type == "child" ? "填写出生日期（必填）" : "填写出生日期", isOn: $hasBirthday)
                    if hasBirthday {
                        DatePicker("出生日期", selection: $birthday, in: ...Date(), displayedComponents: .date)
                    }
                    Toggle("填写出生时刻", isOn: $hasBirthTime)
                    if hasBirthTime {
                        DatePicker("出生时刻", selection: $birthTime, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, NativeLocalDateTime.zone)
                        Stepper("秒数 \(birthSecond)", value: $birthSecond, in: 0...59)
                    }
                    Toggle("显示成长时间线", isOn: $growth)
                } header: { Text("出生与成长") } footer: {
                    Text(growth
                         ? "修改生日会重新计算影像年龄。"
                         : "关闭后仍可关联和筛选影像。")
                }
                Section(pet ? "关于宠物" : "关于家人") {
                    NativeFormField(title: "档案介绍", hint: "\(notes.unicodeScalars.count) / 10,000") {
                        TextField("", text: $notes, prompt: NativeTheme.inputPrompt("性格、爱好，或你想记下的话…"), axis: .vertical)
                            .lineLimit(4...10)
                    }
                }
                Section {
                    ColorPicker("时间线标识颜色", selection: Binding(get: { displayColor }, set: {
                        if let hex = ProfileColor.hex($0) { theme = hex }
                    }), supportsOpacity: false)
                    NativeFormField(title: "显示顺序") {
                        TextField("", text: $order, prompt: NativeTheme.inputPrompt("0")).keyboardType(.numbersAndPunctuation)
                    }
                    Picker("档案状态", selection: $status) {
                        Text("启用").tag("active")
                        Text("已归档").tag("archived")
                    }
                } header: { Text("显示与管理") } footer: {
                    Text("归档保留资料和影像关联，可恢复启用。")
                }
                if let validation { Text(validation).font(.footnote).foregroundStyle(.red) }
            }
            .disabled(saving || preparingAvatar)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle("编辑家人资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .buttonStyle(NativeActionStyle(kind: .primary, compact: true))
                        .disabled(saving || preparingAvatar || !profile.editable(by: session.account) || validation != nil)
                }
            }
            .nativeSheet(isPresented: $choosingExisting, onDismiss: {
                if let id = existingAvatarToCrop {
                    existingAvatarToCrop = nil
                    Task { await prepareExistingAvatar(id) }
                }
            }) {
                NativeFamilyPhotoSearch(session: session, selectedID: avatarID) { id in
                    existingAvatarToCrop = id
                }
            }
            .nativeSheet(item: $croppingAvatar) { source in
                NativeAvatarCropView(source: source) { cropped in
                    avatarSource = source
                    avatarDraft = cropped
                    avatarKey = UUID()
                }
            }
            .task(id: libraryPhoto) { await prepareAvatar() }
            .alert("操作未完成", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
                Button("知道了", role: .cancel) { error = "" }
            } message: { Text(error) }
        }
        .interactiveDismissDisabled(saving)
    }

    private var avatarSection: some View {
        Section {
            HStack(spacing: 16) {
                NativeFamilyAvatar(session: session, mediaID: avatarID, name: displayName, pet: pet, color: displayColor,
                                   size: 72, draft: avatarDraft.flatMap { UIImage(data: $0.jpeg) })
                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName.isEmpty ? "家人档案" : displayName).font(.title3.bold())
                    Text(avatarDraft != nil || avatarID != profile.avatar_media_id ? "头像改动待保存" : "头像预览")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
            PhotosPicker(selection: $libraryPhoto, matching: .images, preferredItemEncoding: .current) {
                Label("从手机相册选头像", systemImage: "photo.on.rectangle")
            }
            Button("从时间线选头像", systemImage: "clock") { choosingExisting = true }
            if let avatarSource {
                Button("调整头像位置与缩放", systemImage: "crop") { croppingAvatar = avatarSource }
            }
            if avatarID != nil || avatarDraft != nil {
                Button("移除头像", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                    avatarDraft = nil
                    avatarSource = nil
                    avatarID = nil
                    libraryPhoto = nil
                    error = ""
                }
            }
            if preparingAvatar { ProgressView("正在准备头像…") }
            if let progress = avatarProgress { ProgressView("正在上传头像…", value: progress) }
        } header: { Text("档案头像") }
    }

    private func choices(_ title: String, options: [String], value: Binding<String>) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { value.wrappedValue = option }
            }
        } label: { Label(title, systemImage: "list.bullet") }
    }

    private func field(_ title: String, _ placeholder: String, text: Binding<String>) -> some View {
        NativeFormField(title: title) {
            TextField("", text: text, prompt: NativeTheme.inputPrompt(placeholder))
        }
    }

    private static func clock(_ value: String?) -> Date? {
        guard let value else { return nil }
        return NativeLocalDateTime.date("2000-01-01T" + (value.count == 5 ? value + ":00" : value))
    }

    private func prepareAvatar() async {
        guard let libraryPhoto else { return }
        preparingAvatar = true
        error = ""
        defer { preparingAvatar = false }
        do {
            guard let image = try await libraryPhoto.loadTransferable(type: NativeAvatarDraft.self) else {
                throw UploadFailure(message: "未能从系统相册取得头像图片。")
            }
            try Task.checkCancellation()
            croppingAvatar = image
            self.libraryPhoto = nil
        } catch {
            if !Task.isCancelled { self.error = friendly(error) }
        }
    }

    private func prepareExistingAvatar(_ id: Int) async {
        preparingAvatar = true
        error = ""
        defer { preparingAvatar = false }
        do {
            let media: NativeTimelineItem = try await session.get("/media/\(id)")
            guard let file = media.primary else { throw UploadFailure(message: "这张照片暂时无法预览。") }
            let resource: NativeMediaResource = try await session.get("/media/\(id)/files/\(file.id)/url?purpose=preview")
            guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
                throw UploadFailure(message: "照片预览尚未就绪，请稍后重试。")
            }
            let image = try await NativeMediaNetwork.image(url, maximumDimension: 2048)
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { throw UploadFailure(message: "无法读取这张照片。") }
            croppingAvatar = NativeAvatarDraft(jpeg: jpeg)
        } catch { self.error = friendly(error) }
    }

    private func save() async {
        guard profile.editable(by: session.account), !saving, !preparingAvatar, validation == nil, let displayOrder, let owner = session.account?.id else { return }
        saving = true
        error = ""
        defer { saving = false; avatarProgress = nil }
        do {
            if let avatarDraft {
                avatarProgress = 0
                avatarID = try await MultipartUploader.uploadAvatar(avatarDraft.jpeg, key: avatarKey, service: session.uploadAPI(ownerID: owner)) {
                    avatarProgress = $0
                }
                self.avatarDraft = nil
                avatarProgress = nil
            }
            guard session.account?.id == owner else { throw UploadFailure(message: "登录状态已变化，请重新打开档案。") }
            let data: [String: Any] = [
                "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                "nickname": nickname, "profile_type": type, "relationship": relationship,
                "species": species, "breed": breed, "gender": gender.isEmpty ? NSNull() as Any : gender,
                "birthday": hasBirthday ? NativeDay.string(birthday) as Any : NSNull(),
                "birth_time": birthClock as Any? ?? NSNull(),
                "growth_enabled": growth, "description": notes,
                "theme_color": theme, "sort_order": Int(displayOrder),
                "status": status, "avatar_media_id": avatarID as Any? ?? NSNull(),
            ]
            let updated = try await session.updateProfile(id: profile.id, json: data)
            onSaved(updated)
            dismiss()
        } catch { self.error = friendly(error) }
    }
}

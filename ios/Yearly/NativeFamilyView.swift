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
    @State private var editing: UploadProfile?
    @State private var auditing: UploadProfile?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            List {
                if saved {
                    Label("家人资料已保存", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityAddTraits(.isHeader)
                }
                if store.profilesLoading && store.profiles.isEmpty { ProgressView("正在读取家人资料…") }
                if !store.profilesError.isEmpty {
                    Text(store.profilesError).foregroundStyle(.red)
                    Button("重新加载") { Task { await store.loadProfiles() } }
                }
                if store.profiles.isEmpty && !store.profilesLoading && store.profilesError.isEmpty {
                    Text("还没有家人或宠物资料。").foregroundStyle(.secondary)
                }
                ForEach(store.profiles) { profile in
                    VStack(alignment: .leading, spacing: 14) {
                        Button { showTimeline(profile) } label: {
                            HStack(spacing: 14) {
                                NativeFamilyAvatar(session: store.session, mediaID: profile.avatar_media_id,
                                                   name: profile.nickname.isEmpty ? profile.name : profile.nickname,
                                                   pet: profile.profile_type == "pet", color: ProfileColor.color(profile.theme_color))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.nickname.isEmpty ? profile.name : profile.nickname)
                                        .font(.headline).foregroundStyle(.primary)
                                    Text(summary(for: profile)).font(.caption).foregroundStyle(.secondary)
                                    if let birthday = profile.birthday {
                                        Text("出生日期 \(birthday)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityHint("查看此成员的时间线")
                        Text(profile.description.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                             ?? "每一份陪伴，都值得珍藏。")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            if profile.editable(by: store.session.account) {
                                Button { saved = false; editing = profile } label: {
                                    Label("编辑资料", systemImage: "square.and.pencil")
                                }
                                .buttonStyle(NativeActionStyle(compact: true))
                                .accessibilityLabel("编辑\(profile.name)的资料")
                            }
                            Button { auditing = profile } label: {
                                Label("修改记录", systemImage: "clock.arrow.circlepath")
                            }.buttonStyle(NativeActionStyle(compact: true))
                                .accessibilityLabel("查看\(profile.name)的修改日志")
                        }
                    }.padding(.vertical, 10)
                }
            }
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle("家人与宠物")
            .refreshable { await store.loadProfiles() }
            .task { await store.loadProfiles() }
            .sheet(item: $auditing) { profile in
                NavigationStack {
                    NativeAuditView(session: store.session, resourceType: "child", resourceID: String(profile.id))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { auditing = nil } } }
                }
            }
            .sheet(item: $editing) { profile in
                NativeFamilyEditor(session: store.session, profile: profile) { updated in
                    if let index = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[index] = updated
                        store.profiles.sort { ($0.sort_order ?? 0, $0.id) < ($1.sort_order ?? 0, $1.id) }
                    }
                    saved = true
                    onProfileUpdated()
                }
            }
        }
    }

    private func summary(for profile: UploadProfile) -> String {
        let details = profile.profile_type == "pet"
            ? ["宠物", profile.species ?? "", profile.breed ?? ""]
            : [profile.relationship.flatMap { $0.isEmpty ? nil : $0 } ?? (profile.profile_type == "child" ? "孩子" : "家人")]
        return (details + [profile.status == "archived" ? "已归档" : ""]).filter { !$0.isEmpty }.joined(separator: " · ")
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
        _birthday = State(initialValue: profile.birthday.flatMap(NativeDay.date) ?? .now)
        _hasBirthday = State(initialValue: profile.birthday.flatMap(NativeDay.date) != nil)
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
                         ? "填写出生日期后可按年龄浏览，修改日期会重新计算历史影像的年龄。"
                         : "关闭成长时间线后，仍然可以关联和筛选这个档案的影像。")
                }
                Section(pet ? "关于宠物" : "关于家人") {
                    TextField("性格、爱好，或你想记下的话…", text: $notes, axis: .vertical).lineLimit(4...10)
                    Text("\(notes.unicodeScalars.count) / 10,000").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ColorPicker("时间线标识颜色", selection: Binding(get: { displayColor }, set: {
                        if let hex = ProfileColor.hex($0) { theme = hex }
                    }), supportsOpacity: false)
                    LabeledContent("显示顺序") {
                        TextField("0", text: $order).keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("档案状态", selection: $status) {
                        Text("启用").tag("active")
                        Text("已归档").tag("archived")
                    }
                } header: { Text("显示与管理") } footer: {
                    Text("顺序数字越小越靠前。归档会保留原有资料和影像关联，可随时恢复启用。")
                }
                if let validation { Text(validation).font(.footnote).foregroundStyle(.red) }
            }
            .disabled(saving || preparingAvatar)
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(saving)
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
            .sheet(isPresented: $choosingExisting, onDismiss: {
                if let id = existingAvatarToCrop {
                    existingAvatarToCrop = nil
                    Task { await prepareExistingAvatar(id) }
                }
            }) {
                NativeFamilyPhotoSearch(session: session, selectedID: avatarID) { id in
                    existingAvatarToCrop = id
                }
            }
            .sheet(item: $croppingAvatar) { source in
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
        } header: { Text("档案头像") } footer: {
            Text("可拖动和缩放头像，保存专用副本；手机相册或时间线中的来源照片保持原样。")
        }
    }

    private func choices(_ title: String, options: [String], value: Binding<String>) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { value.wrappedValue = option }
            }
        } label: { Label(title, systemImage: "list.bullet") }
    }

    private func field(_ title: String, _ placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text).multilineTextAlignment(.trailing)
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

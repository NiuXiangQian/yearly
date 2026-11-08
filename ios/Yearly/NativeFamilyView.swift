import SwiftUI

struct NativeFamilyView: View {
    @ObservedObject var store: NativeTimelineStore
    let showTimeline: (UploadProfile) -> Void
    let onProfileUpdated: () -> Void
    @State private var editing: UploadProfile?
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
                    HStack {
                        Button { showTimeline(profile) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(profile.label, systemImage: profile.profile_type == "pet" ? "pawprint" : "person.crop.circle")
                                if let birthday = profile.birthday {
                                    Text("生日 \(birthday)").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless)
                        if store.session.canEdit {
                            Button("编辑") { saved = false; editing = profile }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("编辑\(profile.name)的资料")
                        }
                    }
                }
            }
            .navigationTitle("家人与宠物")
            .refreshable { await store.loadProfiles() }
            .task { await store.loadProfiles() }
            .sheet(item: $editing) { profile in
                NativeFamilyEditor(session: store.session, profile: profile) { updated in
                    if let index = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[index] = updated
                    }
                    saved = true
                    onProfileUpdated()
                }
            }
        }
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
    @State private var birthday: Date
    @State private var hasBirthday: Bool
    @State private var birthTime: String
    @State private var growth: Bool
    @State private var notes: String
    @State private var saving = false
    @State private var error = ""

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
        _birthday = State(initialValue: profile.birthday.flatMap(NativeDay.date) ?? .now)
        _hasBirthday = State(initialValue: profile.birthday != nil || profile.profile_type == "child")
        _birthTime = State(initialValue: profile.birth_time ?? "")
        _growth = State(initialValue: profile.growth_enabled ?? (profile.profile_type != "person"))
        _notes = State(initialValue: profile.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本资料") {
                    TextField("姓名", text: $name)
                    TextField("昵称", text: $nickname)
                    Picker("类型", selection: $type) {
                        Text("孩子").tag("child")
                        Text("人物").tag("person")
                        Text("宠物").tag("pet")
                    }
                    if type == "pet" {
                        TextField("物种", text: $species)
                        TextField("品种", text: $breed)
                    } else {
                        TextField("关系", text: $relationship)
                    }
                    TextField("性别", text: $gender)
                }
                Section("生日与成长") {
                    if type != "child" { Toggle("记录生日", isOn: $hasBirthday) }
                    if type == "child" || hasBirthday {
                        DatePicker("生日", selection: $birthday, in: ...Date(), displayedComponents: .date)
                    }
                    TextField("出生时间（如 08:30）", text: $birthTime).keyboardType(.numbersAndPunctuation)
                    Toggle("显示成长时间线", isOn: $growth)
                }
                Section("备注") {
                    TextField("补充资料", text: $notes, axis: .vertical).lineLimit(3...8)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .navigationTitle("编辑家人资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(saving || !session.canEdit || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard !saving else { return }
        let time = birthTime.trimmingCharacters(in: .whitespacesAndNewlines)
        if !time.isEmpty && time != profile.birth_time &&
            time.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?$"#, options: .regularExpression) == nil {
            error = "出生时间请填写 24 小时制时间，例如 08:30。"
            return
        }
        saving = true
        error = ""
        defer { saving = false }
        let data: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "nickname": nickname, "profile_type": type, "relationship": relationship,
            "species": species, "breed": breed, "gender": gender.isEmpty ? NSNull() as Any : gender,
            "birthday": (type == "child" || hasBirthday) ? NativeDay.string(birthday) as Any : NSNull(),
            "birth_time": time.isEmpty ? NSNull() as Any : time,
            "growth_enabled": growth, "description": notes,
            "theme_color": profile.theme_color ?? "#bf775d", "sort_order": profile.sort_order ?? 0,
            "status": profile.status ?? "active", "avatar_media_id": profile.avatar_media_id as Any? ?? NSNull(),
        ]
        do {
            let updated = try await session.updateProfile(id: profile.id, json: data)
            onSaved(updated)
            dismiss()
        } catch { self.error = friendly(error) }
    }
}

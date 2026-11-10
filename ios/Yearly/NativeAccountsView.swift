import SwiftUI

struct NativeAccountsView: View {
    @StateObject private var store: NativeAccountsStore
    @State private var editing: NativeManagedUser?
    @State private var creating = false
    init(session: NativeSession) { _store = StateObject(wrappedValue: NativeAccountsStore(session: session)) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("家庭成员与权限").font(.headline)
                    Text("普通账号编辑自己的内容，管理员管理全部内容与账号。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            Section("家庭账号 · \(store.users.count)") {
                ForEach(store.users) { user in
                    Button { editing = user } label: {
                        HStack(spacing: 12) {
                            Image(systemName: user.role == "admin" ? "person.badge.shield.checkmark" : "person.crop.circle")
                                .font(.system(size: 20)).foregroundStyle(NativeTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(NativeTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(user.username).foregroundStyle(.primary)
                                Text(user.roleLabel + " · " + (user.active ? "启用" : "已停用") + (user.id == store.session.account?.id ? " · 当前账户" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).padding(.vertical, 4).accessibilityLabel("编辑账户 \(user.username)")
                }
                if store.loading { ProgressView("正在读取账户…") }
                if !store.error.isEmpty {
                    Text(store.error).foregroundStyle(.red)
                    Button("重新加载") { Task { await store.load() } }
                }
            }
            Section {
                NavigationLink { NativeAuditView(session: store.session, resourceType: "sys_user") } label: {
                    Label("账户修改日志", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .scrollContentBackground(.hidden).background(NativeTheme.background)
        .navigationTitle("账号管理")
        .safeAreaInset(edge: .bottom) {
            Button { creating = true } label: {
                Label("创建账号", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
            }.buttonStyle(NativeActionStyle(kind: .primary)).padding(16).background(.bar)
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(item: $editing) { user in NativeAccountEditor(store: store, existing: user) }
        .sheet(isPresented: $creating) { NativeAccountEditor(store: store, existing: nil) }
    }
}

private struct NativeAccountEditor: View {
    @ObservedObject var store: NativeAccountsStore
    let existing: NativeManagedUser?
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var password = ""
    @State private var role: String
    @State private var active: Bool
    @State private var busy = false
    @State private var error = ""

    init(store: NativeAccountsStore, existing: NativeManagedUser?) {
        self.store = store; self.existing = existing
        _username = State(initialValue: existing?.username ?? "")
        _role = State(initialValue: existing?.role ?? "member")
        _active = State(initialValue: existing?.active ?? true)
    }
    private var currentAccount: Bool { existing?.id == store.session.account?.id }
    private var valid: Bool {
        NativeAccountValidation.username(username) == nil &&
        NativeAccountValidation.password(password, optional: existing != nil) == nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("账户信息") {
                    TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(NativeAccountValidation.username(username) ?? "用户名可使用文字、数字、下划线、点、@ 和短横线。")
                        .font(.caption)
                        .foregroundStyle(!username.isEmpty && NativeAccountValidation.username(username) != nil ? .red : .secondary)
                    SecureField(existing == nil ? "初始密码，至少 12 个字符" : "新密码，留空保持当前密码", text: $password)
                        .textContentType(.newPassword)
                    Text(NativeAccountValidation.password(password, optional: existing != nil) ?? (existing == nil ? "密码须为 12 至 256 个字符。" : "新密码须为 12 至 256 个字符；留空保持当前密码。"))
                        .font(.caption)
                        .foregroundStyle(!password.isEmpty && NativeAccountValidation.password(password, optional: existing != nil) != nil ? .red : .secondary)
                    Picker("角色", selection: $role) {
                        Text("普通账户").tag("member")
                        Text("管理员").tag("admin")
                        if existing?.role == "viewer" { Text("只读访客").tag("viewer") }
                    }.disabled(currentAccount)
                    if existing != nil { Toggle("启用账户", isOn: $active).disabled(currentAccount) }
                }
                Section {
                    Text("修改用户名、角色或密码，以及停用账户后，该账户需要重新登录。角色变更会撤销已有分享。当前管理员保留自身管理权限。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let existing {
                        NavigationLink("查看此账户的修改日志") {
                            NativeAuditView(session: store.session, resourceType: "sys_user", resourceID: String(existing.id))
                        }
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
                if busy { ProgressView("正在保存账户…") }
            }
            .disabled(busy)
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle(existing == nil ? "创建账号" : "编辑账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        busy = true; error = ""
                        Task {
                            do {
                                try await store.save(existing: existing, username: username, password: password, role: role, active: active)
                                password = ""
                                dismiss()
                            } catch { self.error = friendly(error) }
                            busy = false
                        }
                    }.buttonStyle(NativeActionStyle(kind: .primary, compact: true)).disabled(busy || !valid)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }
}

struct NativePasswordView: View {
    @ObservedObject var session: NativeSession
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        Form {
            Section("修改密码") {
                SecureField("当前密码", text: $current).textContentType(.password)
                if current.isEmpty { Text("请输入当前密码以验证身份。").font(.caption).foregroundStyle(.secondary) }
                SecureField("新密码，至少 12 个字符", text: $new).textContentType(.newPassword)
                Text(NativeAccountValidation.password(new) ?? "新密码须为 12 至 256 个字符。")
                    .font(.caption)
                    .foregroundStyle(!new.isEmpty && NativeAccountValidation.password(new) != nil ? .red : .secondary)
                SecureField("再次输入新密码", text: $confirmation).textContentType(.newPassword)
                if confirmation.isEmpty { Text("请再次输入新密码。").font(.caption).foregroundStyle(.secondary) }
                else if confirmation != new { Text("两次输入的新密码不一致。").font(.caption).foregroundStyle(.red) }
                Button("更新密码并重新登录") {
                    busy = true; error = ""
                    Task {
                        do {
                            try await session.changePassword(current: current, new: new)
                            current = ""; new = ""; confirmation = ""
                            dismiss()
                        } catch { self.error = friendly(error) }
                        busy = false
                    }
                }.buttonStyle(NativeActionStyle(kind: .primary))
                .disabled(current.isEmpty || NativeAccountValidation.password(new) != nil || confirmation != new)
            }
            Section { Text("保存后，此账户的所有登录会话都会失效。 ").font(.footnote).foregroundStyle(.secondary) }
            if busy { ProgressView("正在更新密码…") }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden).background(NativeTheme.background)
        .navigationTitle("修改密码")
        .interactiveDismissDisabled(busy)
    }
}

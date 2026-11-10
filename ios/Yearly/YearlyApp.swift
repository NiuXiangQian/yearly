import SwiftUI

@main
struct YearlyApp: App {
    var body: some Scene { WindowGroup { YearlyRootView() } }
}

struct YearlyRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("yearlySite") private var address = AppConfiguration.defaultSite
    @StateObject private var uploads = UploadQueue()
    @State private var editingSite = false
    var body: some View {
        Group {
            if let site = SiteOrigin(address) {
                NativeAppShell(site: site, queue: uploads) { editingSite = true }.id(address)
                    .sheet(isPresented: $editingSite) {
                        SiteSettings(address: address, canCancel: true) { newAddress in
                            uploads.pauseAll(); address = newAddress; editingSite = false
                        }
                    }
            } else {
                SiteSettings(address: address, canCancel: false) { address = $0 }
            }
        }
        .tint(NativeTheme.accent)
        .onChange(of: scenePhase) { phase in
            if phase == .background { uploads.enteredBackground() }
            if phase == .active { uploads.enteredForeground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            NativeImageCache.clear()
            uploads.pauseAll(); uploads.error = "系统内存紧张，已保存并暂停任务，请稍后继续。"
        }
    }
}

struct NativeAppShell: View {
    @StateObject private var session: NativeSession
    @StateObject private var timeline: NativeTimelineStore
    @ObservedObject var queue: UploadQueue
    let editSite: () -> Void
    @State private var tab = 0
    @State private var loggingOut = false
    @State private var showingShares = false
    @State private var uploadDay: Date?
    @State private var profileRevision = 0
    @State private var message = ""
    init(site: SiteOrigin, queue: UploadQueue, editSite: @escaping () -> Void) {
        let session = NativeSession(site: site)
        _session = StateObject(wrappedValue: session)
        _timeline = StateObject(wrappedValue: NativeTimelineStore(session: session))
        self.queue = queue; self.editSite = editSite
    }
    var body: some View {
        Group {
            if session.restoring {
                ProgressView("正在恢复安全登录状态…")
            } else if session.account == nil {
                NativeLoginView(session: session, editSite: editSite)
            } else {
                TabView(selection: $tab) {
                    NativeTimelineView(store: timeline) { day in
                        uploadDay = NativeDay.date(day)
                        tab = 1
                    }
                        .tabItem { Label("时间线", systemImage: "photo.on.rectangle") }.tag(0)
                    Group {
                        if session.canEdit {
                            NativeUploadView(queue: queue, session: session, profileRevision: profileRevision, requestedDay: $uploadDay) { destination in
                                session.invalidateCachedLists()
                                switch destination {
                                case .timeline:
                                    timeline.focusOnUploads([])
                                    Task { await timeline.load() }
                                case .batch(let mediaIDs):
                                    timeline.focusOnUploads(mediaIDs)
                                case .recentUploads:
                                    timeline.showRecentUploads()
                                    Task { await timeline.load() }
                                }
                                tab = 0
                            }
                        } else {
                            NavigationStack { Text("此账号为只读账号，可以浏览家庭回忆。上传需要家庭编辑权限。").padding().navigationTitle("珍藏原片") }
                        }
                    }.tabItem { Label("上传", systemImage: "square.and.arrow.up") }.tag(1)
                    NativeFamilyView(store: timeline, showTimeline: { profile in
                        timeline.focusOnUploads([])
                        timeline.selected = [profile.id]
                        tab = 0
                    }, onProfileUpdated: { profileRevision += 1 })
                    .tabItem { Label("家人", systemImage: "person.2") }.tag(2)
                    NavigationStack {
                        Form {
                            Section {
                                HStack(spacing: 18) {
                                    Text(String((session.account?.username ?? "家").prefix(1)))
                                        .font(.system(size: 27, weight: .semibold))
                                        .foregroundStyle(NativeTheme.accent).frame(width: 64, height: 64)
                                        .background(NativeTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(session.account?.username ?? "家庭成员").font(.title2.bold())
                                        HStack(spacing: 8) {
                                            Text(session.account?.roleLabel ?? "只读访客")
                                                .font(.caption.weight(.semibold)).foregroundStyle(NativeTheme.accent)
                                                .padding(.horizontal, 9).padding(.vertical, 4)
                                                .background(NativeTheme.accent.opacity(0.08), in: Capsule())
                                            if let account = session.account {
                                                Text("ID \(account.id)").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 10)
                            }
                            Section("管理与记录") {
                                if session.isAdmin {
                                    NavigationLink { NativeAccountsView(session: session) } label: {
                                        NativeSettingsLabel(title: "账号管理", symbol: "person.2.badge.gearshape", detail: "家庭成员、角色与账号状态")
                                    }
                                }
                                NavigationLink { NativeAuditView(session: session) } label: {
                                    NativeSettingsLabel(title: "修改记录", symbol: "clock.arrow.circlepath", detail: "查看文件与设置的变更")
                                }
                                if session.canEdit {
                                    Button { showingShares = true } label: {
                                        HStack {
                                            NativeSettingsLabel(title: "分享管理", symbol: "link", detail: "创建链接、查看访问与撤销分享")
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                            Section {
                                NavigationLink { NativePasswordView(session: session) } label: {
                                    NativeSettingsLabel(title: "修改密码", symbol: "lock.shield")
                                }
                                Button { queue.pauseAll(); editSite() } label: {
                                    HStack {
                                        NativeSettingsLabel(title: "站点与关于", symbol: "globe", detail: session.site.url.host)
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                }.buttonStyle(.plain)
                            } header: { Text("安全与设置") } footer: {
                                Text("会话安全保存在 Keychain，密码不会保存到本机。")
                            }
                            Section {
                                Button { loggingOut = true } label: {
                                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity)
                                }.buttonStyle(NativeActionStyle(kind: .destructive))
                            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                            if !message.isEmpty { Text(message).foregroundStyle(.red) }
                        }.scrollContentBackground(.hidden).background(NativeTheme.background)
                            .navigationTitle("账号")
                            .confirmationDialog("退出后上传将安全暂停", isPresented: $loggingOut, titleVisibility: .visible) {
                                Button("退出登录", role: .destructive) {
                                    queue.pauseAll()
                                    Task { do { try await session.logout() } catch { session.error = friendly(error) } }
                                }
                            }
                    }.tabItem { Label("账号", systemImage: "person.crop.circle") }.tag(3)
                }
            }
        }
        .sheet(isPresented: $showingShares) { NativeSharingView(session: session) }
        .task { await session.restore(); queue.configure(session: session) }
        .onChange(of: session.account?.id) { _ in
            NativeImageCache.clear()
            queue.pauseAll(); queue.configure(session: session)
            showingShares = false
            timeline.resetForAccountChange(); tab = 0
        }
        .onDisappear { queue.pauseAll() }
    }
}

struct NativeLoginView: View {
    @ObservedObject var session: NativeSession
    let editSite: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var answer = ""
    @State private var captcha: LoginCaptcha?
    @State private var loading = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "leaf.fill").font(.largeTitle).foregroundStyle(.tint)
                        Text("让成长有迹可循").font(.title2.bold())
                        Text("登录自己的家庭站点，珍藏原片与实况影像。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical)
                }
                Section("登录家庭账号") {
                    TextField("用户名", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                    HStack {
                        TextField("图片验证码", text: $answer).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button { Task { await refreshCaptcha() } } label: {
                            if let data = captcha?.png, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(width: 150, height: 48)
                            } else { Label("加载验证码", systemImage: "arrow.clockwise").font(.caption) }
                        }.buttonStyle(.borderless).accessibilityLabel("刷新图片验证码").disabled(loading)
                    }
                    Button {
                        guard let captcha else { return }
                        loading = true; message = ""
                        Task {
                            do {
                                try await session.login(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, captcha: captcha, answer: answer)
                                password = ""; answer = ""
                            } catch {
                                message = friendly(error)
                                password = ""
                                await refreshCaptcha()
                            }
                            loading = false
                        }
                    } label: {
                        HStack { Text("登录"); if loading { ProgressView() } }
                    }.buttonStyle(NativeActionStyle(kind: .primary))
                    .frame(maxWidth: .infinity)
                    .disabled(loading || captcha == nil || username.isEmpty || password.isEmpty || answer.isEmpty)
                    if !message.isEmpty { Text(message).foregroundStyle(.red).font(.caption) }
                    if !session.error.isEmpty { Text(session.error).foregroundStyle(.secondary).font(.caption) }
                }
                Section {
                    Text(session.site.url.absoluteString).font(.caption)
                    Button("修改家庭站点地址", action: editSite)
                    Text("首次使用原生版本需重新登录。密码不会写入本机存储，登录会话仅保存到 Keychain。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Yearly")
                .task { await refreshCaptcha() }
        }
    }
    private func refreshCaptcha() async {
        answer = ""; captcha = nil
        do { captcha = try await session.captcha() }
        catch { message = friendly(error) }
    }
}

struct SiteSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    let canCancel: Bool
    let onConnect: (String) -> Void

    init(address: String, canCancel: Bool, onConnect: @escaping (String) -> Void) {
        _draft = State(initialValue: address)
        self.canCancel = canCancel
        self.onConnect = onConnect
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "leaf.fill").font(.system(size: 42)).foregroundStyle(.tint)
                        Text("让成长有迹可循").font(.title2.bold())
                        Text("把照片、实况影像与成长日记，珍藏在自己的家庭站点。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section {
                    TextField("https://example.com/yearly/", text: $draft)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("家庭站点 HTTPS 地址")
                    Button("连接家庭站点") {
                        guard let site = SiteOrigin(draft) else { return }
                        onConnect(site.url.absoluteString)
                    }
                    .disabled(SiteOrigin(draft) == nil)
                } header: { Text("家庭站点") } footer: {
                    Text("请输入已部署的 Yearly HTTPS 地址，可包含安装路径，例如 /yearly/。请去掉查询参数和页面锚点。更换站点会中断当前上传。")
                }
                Section("数据与隐私") {
                    Label("照片仅在你选择并上传后发送至家庭站点配置的存储。", systemImage: "photo.on.rectangle")
                    Label("登录会话安全保存在 Keychain，可在 App 的“我的”页退出；密码不会保存。", systemImage: "lock.shield")
                    if let privacy = AppConfiguration.url(for: "YearlyPrivacyPolicyURL") {
                        Link("隐私政策", destination: privacy)
                    }
                    if let support = AppConfiguration.url(for: "YearlySupportURL") {
                        Link("帮助与支持", destination: support)
                    }
                }.font(.subheadline)
                Section("关于") {
                    LabeledContent("yearly", value: version)
                    Text("原生上传任务自动保存，进入后台暂停，回到前台续传。强制退出后请打开上传任务并继续；不保证后台持续上传。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(canCancel ? "站点与关于" : "欢迎使用 yearly")
            .toolbar {
                if canCancel {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                }
            }
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

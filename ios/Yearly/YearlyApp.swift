import SwiftUI
import UserNotifications

@main
struct YearlyApp: App {
    @UIApplicationDelegateAdaptor(YearlyAppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup { YearlyRootView(appDelegate: appDelegate) } }
}

@MainActor
final class YearlyAppDelegate: NSObject, UIApplicationDelegate {
    let uploads = UploadQueue(backgroundExecution: IOSUploadBackgroundExecution(), reportBackgroundUpdate: IOSUploadNotifications.post)
    private var currentSession: NativeSession?

    func session(for site: SiteOrigin) -> NativeSession {
        if let currentSession, currentSession.site.url == site.url { return currentSession }
        let session = NativeSession(site: site)
        currentSession = session
        return session
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = BackgroundUploadTransport.shared // Reconnect the stable daemon session on every launch.
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploadTransport.identifier else { completionHandler(); return }
        BackgroundUploadTransport.shared.handleEvents { [weak self] in
            Task { @MainActor in
                defer { completionHandler() }
                if application.applicationState == .background { await self?.recoverUploads(whileBackgrounded: true) }
            }
        }
    }

    func recoverUploads(whileBackgrounded: Bool) async {
        let address = UserDefaults.standard.string(forKey: "yearlySite") ?? AppConfiguration.defaultSite
        guard let site = SiteOrigin(address), !uploads.running,
              uploads.items.contains(where: { $0.site == site.url.absoluteString && $0.confirmed && $0.phase == .queued }) else { return }
        if whileBackgrounded { uploads.enteredBackground() }
        let session = session(for: site)
        if session.account == nil {
            guard UIApplication.shared.isProtectedDataAvailable else { return }
            await session.restore()
        }
        if currentSession === session { uploads.configure(session: session) }
    }
}

@MainActor enum IOSUploadNotifications {
    private static let startedIdentifier = "yearly.upload.started"

    static func requestPermission(openSettingsOtherwise: Bool = false) {
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert])
            } else if openSettingsOtherwise, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        }
    }

    static func post(_ update: UploadQueue.BackgroundUpdate) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        let identifier: String
        let trigger: UNNotificationTrigger?
        switch update {
        case .started(let count):
            content.title = "后台上传"
            content.body = "正在处理 \(count) 项。可返回上传页查看进度。"
            identifier = startedIdentifier
            // Let the Home Screen transition finish before iOS presents the notification.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        case .finished(let completed, let interrupted):
            content.title = interrupted == 0 ? "后台上传完成" : "有上传任务中断"
            content.body = interrupted == 0 ? "已处理 \(completed) 项。" : "\(interrupted) 项待重试。可在上传页点「全部重试」。"
            center.removePendingNotificationRequests(withIdentifiers: [startedIdentifier])
            identifier = "yearly.upload.\(UUID().uuidString)"
            trigger = nil
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

@MainActor final class IOSUploadBackgroundExecution: UploadBackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin(expiration: @escaping @MainActor () -> Void) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "保存上传进度与准备下一分片") { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
                expiration()
            }
        }
        if identifier == .invalid { expiration() }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

struct YearlyRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("yearlySite") private var address = AppConfiguration.defaultSite
    let appDelegate: YearlyAppDelegate
    private var uploads: UploadQueue { appDelegate.uploads }
    @State private var editingSite = false
    @State private var shareSetupError = ""
    var body: some View {
        Group {
            if let site = SiteOrigin(address) {
                NativeAppShell(session: appDelegate.session(for: site), queue: uploads) { editingSite = true }.id(address)
                    .nativeSheet(isPresented: $editingSite) {
                        SiteSettings(address: address, canCancel: true) { newAddress in
                            uploads.pauseAll(); address = newAddress; editingSite = false
                        }
                    }
            } else {
                SiteSettings(address: address, canCancel: false) { address = $0 }
            }
        }
        .tint(NativeTheme.accent)
        .task(id: address) {
            do { try ShareDestinationStore().save(address) }
            catch { shareSetupError = error.localizedDescription }
        }
        .alert("相册分享设置未更新", isPresented: Binding(get: { !shareSetupError.isEmpty }, set: { if !$0 { shareSetupError = "" } })) {
            Button("知道了", role: .cancel) { shareSetupError = "" }
        } message: { Text(shareSetupError) }
        .onChange(of: scenePhase) { phase in
            if phase == .inactive { uploads.prepareForBackground() }
            if phase == .background { uploads.enteredBackground() }
            if phase == .active {
                uploads.enteredForeground()
                Task { await appDelegate.recoverUploads(whileBackgrounded: false) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
            uploads.prepareForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            NativeImageCache.clear()
        }
    }
}

struct NativeAppShell: View {
    @StateObject private var session: NativeSession
    @StateObject private var timeline: NativeTimelineStore
    let queue: UploadQueue
    let editSite: () -> Void
    @State private var tab = 0
    @State private var timelineTopRequest = 0
    @State private var loggingOut = false
    @State private var showingShares = false
    @State private var uploadDay: Date?
    @State private var profileRevision = 0
    @State private var message = ""
    init(session: NativeSession, queue: UploadQueue, editSite: @escaping () -> Void) {
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
                VStack(spacing: 0) {
                    TabView(selection: $tab) {
                        NativeTimelineView(store: timeline, isActive: tab == 0, topRequest: timelineTopRequest) { day in
                            uploadDay = NativeDay.date(day)
                            tab = 1
                        }
                            .tabItem { Label("时间线", systemImage: "photo.on.rectangle") }.tag(0)
                            .toolbar(.hidden, for: .tabBar)
                        Group {
                            if session.canEdit {
                                NativeUploadView(queue: queue, session: session, profileRevision: profileRevision, requestedDay: $uploadDay) { destination in
                                    session.invalidateCachedLists()
                                    switch destination {
                                    case .timeline:
                                        timeline.focusOnUploads([])
                                    case .batch(let mediaIDs):
                                        timeline.focusOnUploads(mediaIDs)
                                    case .recentUploads:
                                        timeline.showRecentUploads()
                                    }
                                    tab = 0
                                }
                            } else {
                                NavigationStack { Text("此账号为只读账号，可以浏览家庭回忆。上传需要家庭编辑权限。").padding().navigationTitle("珍藏原片") }
                            }
                        }.tabItem { Label("上传", systemImage: "square.and.arrow.up") }.tag(1)
                            .toolbar(.hidden, for: .tabBar)
                        NativeFamilyView(store: timeline, showTimeline: { profile in
                            timeline.focusOnUploads([])
                            timeline.selected = [profile.id]
                            tab = 0
                        }, onProfileUpdated: { profileRevision += 1 })
                        .tabItem { Label("家人", systemImage: "person.2") }.tag(2)
                            .toolbar(.hidden, for: .tabBar)
                        NavigationStack {
                            Form {
                                Section {
                                    HStack(spacing: 18) {
                                        Text(String((session.account?.displayName ?? "家").prefix(1)))
                                            .font(.system(.title, design: .serif).weight(.semibold))
                                            .foregroundStyle(NativeTheme.accent).frame(width: 64, height: 64)
                                            .background(NativeTheme.background, in: RoundedRectangle(cornerRadius: 16))
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(session.account?.displayName ?? "家庭成员")
                                                .font(.system(.title2, design: .serif).weight(.semibold))
                                                .accessibilityAddTraits(.isHeader)
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
                                        NavigationLink { NativeOrganizationHomeView(session: session, onUpdated: { Task { await timeline.load(refresh: true) } }) } label: {
                                            NativeSettingsLabel(title: "照片助手", symbol: "sparkles", detail: "整理家人相册 · 自动整理记录")
                                        }
                                        NavigationLink { NativeAccountsView(session: session) } label: {
                                            NativeSettingsLabel(title: "账号管理", symbol: "person.2.badge.gearshape")
                                        }
                                    }
                                    NavigationLink { NativeAuditView(session: session) } label: {
                                        NativeSettingsLabel(title: "修改记录", symbol: "clock.arrow.circlepath")
                                    }
                                    if session.canEdit {
                                        Button { showingShares = true } label: {
                                            HStack {
                                                NativeSettingsLabel(title: "分享管理", symbol: "link")
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
                                } header: { Text("安全与设置") }
                                Section {
                                    Button { loggingOut = true } label: {
                                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right").frame(maxWidth: .infinity)
                                    }.buttonStyle(NativeActionStyle(kind: .destructive))
                                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                                if !message.isEmpty { Text(message).foregroundStyle(.red) }
                            }.scrollContentBackground(.hidden).background(NativeTheme.background)
                                .navigationTitle("账号")
                                .navigationBarTitleDisplayMode(.inline)
                                .confirmationDialog("退出后上传将安全暂停", isPresented: $loggingOut, titleVisibility: .visible) {
                                    Button("退出登录", role: .destructive) {
                                        queue.pauseAll()
                                        Task { do { try await session.logout() } catch { session.error = friendly(error) } }
                                    }
                                }
                        }.tabItem { Label("账号", systemImage: "person.crop.circle") }.tag(3)
                            .toolbar(.hidden, for: .tabBar)
                        if session.isAdmin {
                            NavigationStack {
                                NativeOrganizationHomeView(session: session, onUpdated: { Task { await timeline.load(refresh: true) } })
                            }.tabItem { Label("照片助手", systemImage: "sparkles") }.tag(4)
                                .toolbar(.hidden, for: .tabBar)
                        }
                    }
                    .clipped()
                    NativeLiquidNavigation(selection: $tab, showsMemoryReview: session.isAdmin) { timelineTopRequest += 1 }
                }
                .background(NativeTheme.background)
            }
        }
        .nativeSheet(isPresented: $showingShares) { NativeSharingView(session: session) }
        .task {
            if session.account == nil { await session.restore() }
            queue.configure(session: session)
        }
        .onChange(of: session.account?.id) { _ in
            NativeImageCache.clear()
            queue.configure(session: session)
            showingShares = false
            timeline.resetForAccountChange(); tab = 0
        }
    }
}

struct NativeLoginView: View {
    @ObservedObject var session: NativeSession
    let editSite: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var username: String
    @State private var password = ""
    @State private var answer = ""
    @State private var captcha: LoginCaptcha?
    @State private var loading = false
    @State private var loadingCaptcha = false
    @State private var message = ""
    @State private var captchaError = ""

    init(session: NativeSession, editSite: @escaping () -> Void) {
        self.session = session
        self.editSite = editSite
        _username = State(initialValue: session.rememberedUsername)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if verticalSizeClass != .compact {
                            Image(decorative: "FamilyAlbumCover")
                                .resizable()
                                .scaledToFill()
                                .frame(height: 132)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Text("欢迎回家")
                            .font(NativeTheme.display)
                            .accessibilityAddTraits(.isHeader)
                        Text("登录自己的家庭站点，珍藏原片与实况影像。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section("登录家庭账号") {
                    NativeFormField(title: "用户名") {
                        TextField("", text: $username, prompt: NativeTheme.inputPrompt("家庭账户")).textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    NativeFormField(title: "密码") {
                        SecureField("", text: $password).textContentType(.password)
                    }
                    captchaInputs
                    if !captchaError.isEmpty {
                        Label(captchaError, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(NativeTheme.inputError)
                    }
                    Button {
                        guard let captcha, !loading, !loadingCaptcha else { return }
                        loading = true; message = ""
                        Task {
                            do {
                                try await session.login(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, captcha: captcha, answer: answer)
                                password = ""; answer = ""
                            } catch {
                                message = friendly(error)
                                await refreshCaptcha()
                            }
                            loading = false
                        }
                    } label: {
                        HStack {
                            Text(loading ? "正在登录…" : "登录")
                            if loading { ProgressView().tint(NativeTheme.onAccent) }
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(NativeActionStyle(kind: .primary))
                    .disabled(loading || loadingCaptcha || captcha == nil || username.isEmpty || password.isEmpty || answer.isEmpty)
                    if !message.isEmpty { Text(message).foregroundStyle(.red).font(.caption) }
                    if !session.error.isEmpty { Text(session.error).foregroundStyle(.secondary).font(.caption) }
                }
                Section {
                    Text(session.site.url.absoluteString).font(.caption)
                    Button("修改家庭站点地址", action: editSite)
                }
            }
                .scrollContentBackground(.hidden)
                .background(NativeTheme.background)
                .navigationTitle("yearly")
                .navigationBarTitleDisplayMode(.inline)
                .task { await refreshCaptcha() }
        }
    }
    @ViewBuilder private var captchaInputs: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedCaptchaInputs
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    captchaField.frame(minWidth: 132)
                    captchaControl.fixedSize(horizontal: true, vertical: false).padding(.bottom, 6)
                }
                stackedCaptchaInputs
            }
        }
    }

    private var stackedCaptchaInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            captchaField
            captchaControl
        }
    }

    private var captchaField: some View {
        NativeFormField(title: "图片验证码") {
            TextField("", text: $answer)
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
        }
    }
    private var captchaControl: some View {
        Button { Task { await refreshCaptcha() } } label: {
            if loadingCaptcha { ProgressView().frame(minHeight: 44) }
            else if let data = captcha?.png, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 126, height: 44)
            } else {
                Label("获取验证码", systemImage: "arrow.clockwise").frame(minHeight: 44)
            }
        }.buttonStyle(.borderless).accessibilityLabel("刷新图片验证码").disabled(loading || loadingCaptcha)
    }
    private func refreshCaptcha() async {
        guard !loadingCaptcha else { return }
        loadingCaptcha = true
        captchaError = ""
        answer = ""
        captcha = nil
        defer { loadingCaptcha = false }
        do { captcha = try await session.captcha() }
        catch { captchaError = friendly(error) }
    }
}

struct SiteSettings: View {
    @NativeDismiss private var dismiss
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
                    NativeFormField(
                        title: "家庭站点 HTTPS 地址",
                        error: !draft.isEmpty && SiteOrigin(draft) == nil
                            ? "请输入有效的 HTTPS 站点地址，并去掉查询参数和页面锚点。" : nil
                    ) {
                        TextField("", text: $draft, prompt: NativeTheme.inputPrompt("https://example.com/yearly/"))
                            .textContentType(.URL).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("连接家庭站点") {
                        guard let site = SiteOrigin(draft) else { return }
                        onConnect(site.url.absoluteString)
                    }
                    .disabled(SiteOrigin(draft) == nil)
                } header: { Text("家庭站点") } footer: {
                    Text("填写家庭站点 HTTPS 地址，保留安装路径。更换站点会中断当前上传。")
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

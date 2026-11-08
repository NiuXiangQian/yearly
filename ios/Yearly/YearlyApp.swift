import SwiftUI
import WebKit

@main
struct YearlyApp: App {
    var body: some Scene {
        WindowGroup { YearlyRootView() }
    }
}

struct YearlyRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("yearlySite") private var address = AppConfiguration.defaultSite
    @StateObject private var browser = BrowserState()
    @StateObject private var uploads = UploadQueue()
    @State private var editingSite = false
    @State private var showingUploads = false

    var body: some View {
        Group {
            if let site = SiteOrigin(address) {
                VStack(spacing: 0) {
                    HStack {
                        Button { browser.webView?.goBack() } label: {
                            Image(systemName: "chevron.backward").frame(width: 44, height: 44)
                        }
                        .disabled(!browser.canGoBack)
                        .accessibilityLabel("返回")
                        Spacer(minLength: 0)
                        Label(site.url.host ?? "yearly", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { showingUploads = true } label: {
                            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("原生相册上传与任务")
                        Menu {
                            Button("原生相册上传与任务") { showingUploads = true }
                            Button { browser.retry(site: site) } label: {
                                Label("重新加载", systemImage: "arrow.clockwise")
                            }
                            Button { editingSite = true } label: {
                                Label("站点与关于", systemImage: "gearshape")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("App 菜单")
                    }
                    .padding(.horizontal, 8)
                    Divider()
                    ZStack {
                        SiteView(site: site, state: browser).id(address)
                        if browser.loadFailed {
                            VStack(spacing: 18) {
                                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                                Text("暂时无法连接家庭站点").font(.headline)
                                Text("请检查网络、站点地址和 HTTPS 证书，然后重试。")
                                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("重新连接") { browser.retry(site: site) }.buttonStyle(.borderedProminent)
                                Button("修改站点地址") { editingSite = true }
                            }
                            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(.systemBackground))
                        } else if browser.isLoading {
                            ProgressView("正在连接…")
                                .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    if browser.isDownloading {
                        HStack { ProgressView(); Text("正在下载，完成后可存储到文件…").font(.caption) }
                            .padding(10)
                    }
                }
                .sheet(isPresented: $editingSite) {
                    SiteSettings(address: address, canCancel: true) { newAddress in
                        uploads.pauseAll()
                        address = newAddress
                        editingSite = false
                    }
                }
                .sheet(isPresented: $showingUploads) {
                    NativeUploadView(queue: uploads, site: site,
                                     cookieStore: browser.webView?.configuration.websiteDataStore.httpCookieStore ?? WKWebsiteDataStore.default().httpCookieStore) {
                        browser.webView?.load(URLRequest(url: site.url))
                    }
                }
                .alert("下载未完成", isPresented: $browser.downloadFailed) {
                    Button("好", role: .cancel) {}
                } message: { Text("请检查网络后重试，并等待当前操作完成。") }
            } else {
                SiteSettings(address: address, canCancel: false) { address = $0 }
            }
        }
        .tint(Color(red: 0.40, green: 0.48, blue: 0.36))
        .onChange(of: scenePhase) { phase in
            if phase == .background { uploads.enteredBackground() }
            if phase == .active { uploads.enteredForeground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            uploads.pauseAll()
            uploads.error = "系统内存紧张，已保存并暂停任务，请稍后继续。"
        }
    }
}

private struct SiteSettings: View {
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
                    Label("登录状态保存在 App 内；退出账号请使用站点中的退出登录。", systemImage: "lock.shield")
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

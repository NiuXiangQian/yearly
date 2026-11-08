import SwiftUI
import AVKit

// Signed media never receives the account Cookie or CSRF token. No shared disk cache.
enum NativeMediaNetwork {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: UploadRedirectPolicy(), delegateQueue: nil)
    }()
    static func image(_ url: URL) async throws -> UIImage {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 20 * 1024 * 1024,
              let image = UIImage(data: data) else { throw UploadFailure(message: "图片预览暂时不可用，请重试。") }
        return image
    }
}

struct NativeMediaImage: View {
    @ObservedObject var session: NativeSession
    let mediaID: Int
    let fileID: Int
    var purpose = "thumbnail"
    @State private var image: UIImage?
    @State private var failure = ""
    @State private var attempt = 0
    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if !failure.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Button("重试预览") { attempt += 1 }
                }.font(.caption)
            } else { ProgressView() }
        }
        .task(id: "\(mediaID)-\(fileID)-\(purpose)-\(attempt)") {
            image = nil; failure = ""
            do {
                let resource: NativeMediaResource = try await session.get("/media/\(mediaID)/files/\(fileID)/url?purpose=\(purpose)")
                guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
                    throw UploadFailure(message: "预览正在准备。")
                }
                let result = try await NativeMediaNetwork.image(url)
                try Task.checkCancellation()
                image = result
            } catch { if !Task.isCancelled { failure = friendly(error) } }
        }
        .accessibilityLabel(failure.isEmpty ? "影像预览" : failure)
    }
}

struct NativeTimelineView: View {
    @ObservedObject var store: NativeTimelineStore
    @State private var showingFilter = false
    @State private var shareRequest: NativeShareRequest?
    @State private var selecting = false
    @State private var chosen: [NativeTimelineItem] = []
    @State private var selectionLimit = false
    @State private var selectedItem: NativeTimelineItem?
    private var days: [String] { Array(Set(store.items.map(\.day))).sorted { a, b in a == "日期未知" ? false : b == "日期未知" ? true : store.ascending ? a < b : a > b } }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Picker("影像类型", selection: $store.mediaType) {
                        Text("全部").tag(""); Text("照片").tag("photo")
                        Text("实况").tag("live_photo"); Text("视频").tag("video")
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("\(store.total) 份家庭回忆").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if store.hasFilters { Button("清除筛选") { store.resetFilters() }.font(.caption) }
                    }
                    if !store.error.isEmpty {
                        Text(store.error).foregroundStyle(.red)
                        Button("重新加载") { Task { await store.load() } }
                    }
                    if store.items.isEmpty && !store.loading { Text(store.hasFilters ? "没有符合条件的回忆，试试其他关键词或日期。" : "还没有回忆，去上传页珍藏第一张照片吧。") }
                    ForEach(days, id: \.self) { day in
                        Section {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                                ForEach(store.items.filter { $0.day == day }, id: \.stableID) { item in
                                    Button {
                                        if selecting {
                                            if let index = chosen.firstIndex(where: { $0.id == item.id }) { chosen.remove(at: index) }
                                            else if chosen.count < 200 { chosen.append(item) }
                                            else { selectionLimit = true }
                                        } else { selectedItem = item }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            if let file = item.primary {
                                                NativeMediaImage(session: store.session, mediaID: item.id, fileID: file.id)
                                                    .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
                                                    .overlay(alignment: .bottomLeading) {
                                                        if item.media_type == "live_photo" { Label("LIVE", systemImage: "livephoto").font(.caption2.bold()).padding(5).background(.regularMaterial, in: Capsule()).padding(7) }
                                                        if item.media_type == "video" { Image(systemName: "play.fill").padding(8).background(.regularMaterial, in: Circle()).padding(7) }
                                                    }
                                            } else {
                                                Image(systemName: "book.closed").frame(maxWidth: .infinity).frame(height: 150).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                                            }
                                            Text(item.label).font(.caption).lineLimit(2)
                                        }
                                    }.buttonStyle(.plain)
                                    .disabled(selecting && item.kind != "media")
                                    .overlay(alignment: .topTrailing) {
                                        if selecting && item.kind == "media" {
                                            Image(systemName: chosen.contains(where: { $0.id == item.id }) ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(.tint).padding(7).background(.regularMaterial, in: Circle()).allowsHitTesting(false)
                                        }
                                    }
                                    .contextMenu {
                                        if store.session.canEdit && item.kind == "media" {
                                            Button("分享这项影像", systemImage: "square.and.arrow.up") { shareRequest = NativeShareRequest(items: [item]) }
                                        }
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(day).font(.title3.bold())
                                Spacer()
                                if store.session.canEdit && NativeDay.date(day) != nil {
                                    Button { shareRequest = NativeShareRequest(day: day) } label: { Label("分享当天", systemImage: "square.and.arrow.up") }.font(.caption)
                                }
                            }
                        }
                    }
                    if store.loading { ProgressView().frame(maxWidth: .infinity) }
                    if store.cursor != nil { Button("加载更早的回忆") { Task { await store.load(more: true) } }.frame(maxWidth: .infinity).disabled(store.loading) }
                }.padding()
            }
            .navigationTitle("家庭时光")
            .searchable(text: $store.search, prompt: "搜索标题、批次、备注或地点")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if store.session.canEdit {
                            Button(selecting ? "取消" : "选择") { selecting.toggle(); chosen = [] }
                            Button { shareRequest = NativeShareRequest() } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享与管理") }
                        Button { showingFilter = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("人物、日期与排序")
                    }
                }
            }
            .refreshable { await store.loadProfiles(); await store.load() }
            .task { await store.loadProfiles() }
            .task(id: store.queryKey) {
                do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation(); await store.load() } catch { }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Text("已选 \(chosen.count) / 200 项")
                        Spacer()
                        Button("分享所选") { shareRequest = NativeShareRequest(items: chosen) }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
                    }.padding().background(.regularMaterial)
                }
            }
            .alert("一次最多分享 200 项", isPresented: $selectionLimit) { Button("知道了", role: .cancel) { } }
            .sheet(item: $shareRequest) { request in
                NativeSharingView(session: store.session, day: request.day, selectedItems: request.items)
            }
            .sheet(isPresented: $showingFilter) {
                NavigationStack {
                    List {
                        Section("时间与排序") {
                            Toggle("从早到晚", isOn: $store.ascending)
                            Toggle("按日期范围查找", isOn: $store.useDateRange)
                            if store.useDateRange {
                                DatePicker("开始日期", selection: $store.startDate, displayedComponents: .date)
                                DatePicker("结束日期", selection: $store.endDate, displayedComponents: .date)
                                Text("按归档日期查找，包含结束当天。未知日期不在日期范围中。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("清除所有筛选") { store.resetFilters() }
                        Button("所有家人") { store.selected = [] }
                        ForEach(store.profiles) { profile in
                            Toggle(profile.label, isOn: Binding(get: { store.selected.contains(profile.id) }, set: { if $0 { store.selected.insert(profile.id) } else { store.selected.remove(profile.id) } }))
                        }
                    }.navigationTitle("筛选与排序")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingFilter = false } } }
                }
            }
            .fullScreenCover(item: $selectedItem) { item in
                NativeMediaDetail(session: store.session, initial: item, profiles: store.profiles) { Task { await store.load() } }
            }
        }
    }
}

struct NativeMediaDetail: View {
    @ObservedObject var session: NativeSession
    let initial: NativeTimelineItem
    let profiles: [UploadProfile]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: NativeTimelineItem?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var message = ""
    @State private var observation: NSKeyValueObservation?
    @State private var playbackTask: Task<Void, Never>?
    @State private var showingInfo = false
    @State private var showingShare = false
    @State private var zoom = 1.0
    @State private var imageScale = 1.0
    private var item: NativeTimelineItem { detail ?? initial }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    if item.kind == "event" {
                        ScrollView { Text(item.content ?? "").frame(maxWidth: .infinity, alignment: .leading).padding() }.foregroundStyle(.white)
                    } else if let player {
                        VideoPlayer(player: player).onDisappear { player.pause() }
                            .overlay {
                                if item.media_type == "live_photo" {
                                    Button(action: play) { Color.clear.contentShape(Rectangle()) }
                                        .buttonStyle(.plain).accessibilityLabel("从头播放实况照片")
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if item.media_type == "live_photo" { liveBadge }
                            }
                    } else if let file = item.primary {
                        NativeMediaImage(session: session, mediaID: item.id, fileID: file.id, purpose: item.media_type == "video" ? "thumbnail" : "preview")
                            .scaleEffect(zoom)
                            .gesture(MagnificationGesture().onChanged { zoom = min(4, max(1, imageScale * $0)) }.onEnded { _ in imageScale = zoom })
                            .clipped()
                            .onTapGesture { if item.media_type == "live_photo" { play() } }
                            .overlay(alignment: .topLeading) {
                                if item.media_type == "live_photo" { liveBadge }
                            }
                    }
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.white).padding(.horizontal) }
                    if loading { ProgressView("正在准备预览…").tint(.white).foregroundStyle(.white) }
                    HStack {
                        if item.media_type == "video" || item.motion != nil {
                            Button(player == nil ? "有声播放" : "重新播放") { play() }.buttonStyle(.borderedProminent).disabled(loading)
                        }
                        if item.motion != nil {
                            Button("静态照片") { stop(); message = "" }.buttonStyle(.bordered)
                        }
                        if zoom != 1 { Button("适应屏幕") { zoom = 1; imageScale = 1 } }
                    }.padding(.bottom)
                }
            }
            .navigationTitle(item.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { stop(); dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        if session.canEdit && (item.kind != "event" || NativeDay.date(item.day) != nil) {
                            Button { stop(); showingShare = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(item.kind == "event" ? "分享当天回忆" : "分享这项影像")
                        }
                        Button { showingInfo = true } label: { Image(systemName: "info.circle") }
                    }
                }
            }
            .task {
                guard initial.kind != "event" else { return }
                if initial.media_type == "live_photo" { play() }
                do { detail = try await session.get("/media/\(initial.id)") }
                catch { message = friendly(error) }
            }
            .sheet(isPresented: $showingShare) { NativeSharingView(session: session, day: item.day, selectedItems: item.kind == "event" ? nil : [item]) }
            .sheet(isPresented: $showingInfo) { NativeMediaInfo(session: session, item: item, profiles: profiles) {
                onSaved()
                Task { do { detail = try await session.get("/media/\(initial.id)") } catch { message = friendly(error) } }
            } }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                if let ended = notification.object as? AVPlayerItem, ended === player?.currentItem, item.motion != nil { stop() }
            }
            .onDisappear { stop() }
            .onChange(of: scenePhase) { if $0 != .active { stop() } }
        }
    }
    private var liveBadge: some View {
        Button(action: play) {
            Label("LIVE", systemImage: "livephoto").padding(8).background(.regularMaterial, in: Capsule())
        }.buttonStyle(.plain).padding().accessibilityLabel("从头播放实况照片")
    }
    private func stop() {
        observation?.invalidate(); observation = nil
        playbackTask?.cancel(); playbackTask = nil
        let hadPlayer = player != nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; loading = false
        if hadPlayer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func play() {
        stop(); message = ""; loading = true
        guard let file = item.motion ?? item.primary else { loading = false; return }
        playbackTask = Task {
            do {
                let resource: NativeMediaResource = try await session.get("/media/\(item.id)/files/\(file.id)/url?purpose=preview")
                try Task.checkCancellation()
                guard let raw = resource.url, let url = AppConfiguration.httpsURL(raw) else {
                    throw UploadFailure(message: resource.status == "failed" ? "动态预览生成失败，请稍后重试。原件已安全保存。" : "动态预览正在生成，请稍后再试。")
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                // AVPlayer receives only the backend's signed media URL, never login headers.
                let value = AVPlayer(url: url)
                value.isMuted = false; value.volume = 1
                player = value
                observation = value.currentItem?.observe(\.status, options: [.new]) { playbackItem, _ in
                    if playbackItem.status == .failed {
                        Task { @MainActor in
                            guard player === value else { return }
                            stop(); message = "播放失败，请点有声播放重新获取预览。"
                        }
                    }
                }
                value.play()
            } catch { if !Task.isCancelled { message = friendly(error) } }
            if !Task.isCancelled { loading = false }
        }
    }
}

struct NativeMediaInfo: View {
    @ObservedObject var session: NativeSession
    let item: NativeTimelineItem
    let profiles: [UploadProfile]
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var children: Set<Int> = []
    @State private var message = ""
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("原始信息") {
                    LabeledContent("拍摄时间", value: item.taken_at_local ?? "未知")
                    LabeledContent("归档日期", value: item.day)
                    if let place = item.location_name, !place.isEmpty { Text(place) }
                    if let remark = item.remark, !remark.isEmpty { Text(remark) }
                    ForEach(item.files ?? []) { file in
                        VStack(alignment: .leading) {
                            Text(file.original_filename)
                            Text("\(file.file_role) · \(ByteCountFormatter.string(fromByteCount: file.file_size, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if item.kind != "event" {
                    Section("人物与宠物") {
                        ForEach(profiles) { profile in
                            Toggle(profile.label, isOn: Binding(get: { children.contains(profile.id) }, set: { if $0 { children.insert(profile.id) } else { children.remove(profile.id) } })).disabled(!session.canEdit)
                        }
                        if session.canEdit {
                            Button("保存关联") {
                                saving = true
                                Task {
                                    do { try await session.write("/media/batch-children", method: "POST", json: ["media_ids": [item.id], "child_ids": children.sorted(), "mode": "replace"]); onSaved(); dismiss() }
                                    catch { message = friendly(error) }
                                    saving = false
                                }
                            }.disabled(saving)
                        }
                    }
                }
                if !message.isEmpty { Text(message).foregroundStyle(.red) }
            }.navigationTitle("影像信息")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .onAppear { children = Set(item.child_ids ?? []) }
        }
    }
}
